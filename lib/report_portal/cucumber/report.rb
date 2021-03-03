require 'cucumber/formatter/io'
require 'cucumber/formatter/hook_query_visitor'
require 'cucumber/formatter/junit'
require 'tree'
require 'securerandom'
require 'redis'
require 'shared/poll'

require_relative '../../reportportal'
require_relative '../logging/logger'
require_relative '../error_reporter'
# rubocop: disable Metrics/ClassLength
module ReportPortal
  module Cucumber
    # @api private
    class Report
      def parallel?
        false
      end

      def attach_to_launch?
        ReportPortal::Settings.instance.formatter_modes.include?('attach_to_launch')
      end

      def initialize
        @last_used_time = 0
        @root_node = Tree::TreeNode.new('')
        @parent_item_node = @root_node
        @error_reporter = ::ReportPortal::ErrorReporter.new
        start_launch
      end

      def redis_client
        @redis_port ||= ENV.fetch('REPORT_PORTAL_REDIS_PORT', '6379') # { raise('Redis server port is undefined in RP_REDIS_PORT') }
        @redis_client ||= Redis.new(url: "redis://127.0.0.1:#{@redis_port}")
        @redis_client
      end

      def start_launch(desired_time = ReportPortal.now)
        if attach_to_launch?
          ReportPortal.launch_id =
            if ReportPortal::Settings.instance.launch_id
              ReportPortal::Settings.instance.launch_id
            else
              file_path = ReportPortal::Settings.instance.file_with_launch_id || (Pathname(Dir.tmpdir) + 'rp_launch_id.tmp')
              File.read(file_path)
            end
          $stdout.puts "Attaching to launch #{ReportPortal.launch_id}"
        else
          description = ReportPortal::Settings.instance.description
          description ||= ARGV.map { |arg| arg.gsub(/rp_uuid=.+/, 'rp_uuid=[FILTERED]') }.join(' ')
          ReportPortal.start_launch(description, time_to_send(desired_time))
        end
      end

      # TODO: time should be a required argument
      def test_case_started(event, desired_time = ReportPortal.now)
        test_case = event.test_case
        feature = test_case.feature
        if report_hierarchy? && !same_feature_as_previous_test_case?(feature)
          end_feature(desired_time) unless @parent_item_node.is_root?
          start_feature_with_parentage(feature, desired_time, test_case)
        end

        name_builder = ::Cucumber::Formatter::NameBuilder.new(test_case)
        name = name_builder.scenario_name
        name += " (Example: #{name_builder.row_name})" unless name_builder.row_name.empty?

        description = test_case.location.to_s
        tags = test_case.tags.map(&:name)
        type = :STEP

        ReportPortal.current_scenario = ReportPortal::TestItem.new(
          name: name,
          type: type,
          id: nil,
          start_time: time_to_send(desired_time),
          description: description,
          closed: false,
          tags: tags,
          retry: ENV['RP_TEST_RETRY']
        )

        scenario_node = Tree::TreeNode.new(SecureRandom.hex, ReportPortal.current_scenario)
        @parent_item_node << scenario_node
        ReportPortal.current_scenario.id = ReportPortal.start_item(scenario_node)
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to #{__method__}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      def stringify_bactrace(backtrace)
        backtrace.take(15).map { |element| element.to_s.tr('\'', '').tr('`', '') }.join("\n")
      end

      def test_case_finished(event, desired_time = ReportPortal.now)
        result = event.result
        status = result.to_sym
        issue = nil
        if %i[undefined pending].include?(status)
          status = :failed
          issue = result.message
        end
        ReportPortal.finish_item(ReportPortal.current_scenario, status, time_to_send(desired_time), issue)
        ReportPortal.current_scenario = nil
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to #{__method__}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      def test_step_started(event, desired_time = ReportPortal.now)
        test_step = event.test_step
        if step?(test_step) # `after_test_step` is also invoked for hooks
          step_source = test_step.source.last
          message = "#{format('%5s', step_source.keyword)} #{step_source.name}"
          if step_source.multiline_arg.doc_string?
            message << %(\n"""\n#{step_source.multiline_arg.content}\n""")
          elsif step_source.multiline_arg.data_table?
            max_chars = step_source.multiline_arg.raw.flatten.map(&:length).max
            message << step_source.multiline_arg.raw.reduce("\n") { |acc, row| acc << "| #{row.map { |item| padded(item, max_chars) }.join(' | ')} |\n" }
          end
          ReportPortal.send_log(:trace, message, time_to_send(desired_time))
        end
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to #{__method__}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      def padded(item, max_chars)
        leading_count  = (max_chars - item.length) / 2
        trailing_count = max_chars - item.length - leading_count
        format('%s%s%s', ' ' * leading_count, item, ' ' * trailing_count)
      end

      NON_BREAKING_SPACES = '    '.freeze
      CURRENT_DIR         = Dir.pwd + '/'
      STACK_FRAME_REGEX   = /(?<file_line>.*:\d+):in `(?<method>.*)'/.freeze

      def format_error(exception, indent_amount = 1)
        msg = "#{exception.message}\n(#{exception.class.name})\n\n"

        msg << exception
               .backtrace
               .map do |line|
          trace_element = line.split(CURRENT_DIR).last
          match         = STACK_FRAME_REGEX.match(trace_element)
          file_line     = match.named_captures['file_line']
          file_line     = file_line.gsub(Dir.pwd, '')
          if file_line.include?('/.rvm/')
            file_line = file_line.gsub(/.*\/\.rvm\//, '')
          end

          if file_line.include?('test_feature_')
            path_components = file_line.split('/')
            feature_folder_index = path_components.index { |e| e.start_with?('test_feature_') }
            path_components = path_components.drop(feature_folder_index + 1)
            file_line = path_components.join('/')
          end

          method        = match.named_captures['method']

          # "#{file_line} #{method} [Open in RubyMine](http://localhost:63342/api/file/#{file_line})"
          # "`#{file_line}`  [IDE](http://localhost:63342/api/file/#{file_line})  in: `#{method}`"
          # "`#{file_line}`  <a class=\"IDE\" href=\"http://localhost:63342/api/file/#{file_line}\">IDE</a>  in: `#{method}`"
          # "`#{file_line}`  <button class=\"IDE\" link=\"http://localhost:63342/api/file/#{file_line}\">IDE</button>  in: `#{method}`"
          # "`#{file_line}`  <button class=\"IDE\" link=\"http://localhost:63342/api/file/#{file_line}\" onclick=\"alert('asdf')\">IDE</button>  in: `#{method}`"
          # https://plugins.jetbrains.com/plugin/11344-jlink

          "`#{file_line}`  in:  **#{method}**"
        end
               .join("\n")
        msg << "\n\nCaused by:\n#{format_error(exception.cause, indent_amount + 1)}" unless exception.cause.nil?

        msg
      end

      def test_step_finished(event, desired_time = ReportPortal.now)
        test_step = event.test_step
        result = event.result
        status = result.to_sym

        if %i[failed pending undefined].include?(status)
          exception_info = if %i[failed pending].include?(status)
                             format_error(result.exception)
                           else
                             format("Undefined step: %s:\n%s", test_step.name, test_step.source.last.backtrace_line)
                           end
          ReportPortal.send_log(:error, exception_info, time_to_send(desired_time))

        elsif status != :passed
          log_level = status == :skipped ? :warn : :error
          step_type = if step?(test_step)
                        'Step'
                      else
                        hook_class_name = test_step.source.last.class.name.split('::').last
                        location = test_step.location
                        "#{hook_class_name} at `#{location}`"
                      end
          ReportPortal.send_log(log_level, "#{step_type} #{status}", time_to_send(desired_time))
        end
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to #{__method__}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      def test_run_finished(_event, desired_time = ReportPortal.now)
        end_feature(desired_time) unless @parent_item_node.is_root?

        unless attach_to_launch?
          close_all_children_of(@root_node) # Folder items are closed here as they can't be closed after finishing a feature
          time_to_send = time_to_send(desired_time)
          ReportPortal.finish_launch(time_to_send)
        end
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to #{__method__}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      def puts(message, desired_time = ReportPortal.now)
        ReportPortal.send_log(:info, message, time_to_send(desired_time))
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to #{__method__}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      def embed(path_or_src, mime_type, label, desired_time = ReportPortal.now)
        return if path_or_src.start_with?('http://', 'https://')

        ReportPortal.send_file(:info, path_or_src, label, time_to_send(desired_time), mime_type)
      rescue => e
        @error_reporter.send_error(
          {
            error_marker: __method__.to_s,
            error_type: "#{e.class}",
            error_message: e.message,
            backtrace: stringify_bactrace(e.backtrace),
          }
        )
        ::Shared::Logging::BadooLogger.log.error("Got exception trying to embed resource #{path_or_src}, #{mime_type}, #{label}. Exception: #{e.class} #{e.message}\n#{e.backtrace}")
      end

      private

      # Report Portal sorts logs by time. However, several logs might have the same time.
      #   So to get Report Portal sort them properly the time should be different in all logs related to the same item.
      #   And thus it should be stored.
      # Only the last time needs to be stored as:
      #   * only one test framework process/thread may send data for a single Report Portal item
      #   * that process/thread can't start the next test until it's done with the previous one
      def time_to_send(desired_time)
        time_to_send = desired_time
        if time_to_send <= @last_used_time
          time_to_send = @last_used_time + 1
        end
        @last_used_time = time_to_send
      end

      def same_feature_as_previous_test_case?(feature)
        @parent_item_node.name == feature.location.file.split(File::SEPARATOR).last
      end

      # rubocop: disable Metrics/AbcSize
      # rubocop: disable Metrics/BlockLength
      # rubocop: disable Metrics/BlockNesting
      # rubocop: disable Metrics/MethodLength
      # rubocop: Metrics/LineLength
      def start_feature_with_parentage(feature, desired_time, test_case)
        parent_node = @root_node
        child_node = nil
        path_components = feature.location.file.split(File::SEPARATOR).reject(&:empty?)
        service_folder_index = path_components.index { |e| %w[functional liveshots].include?(e) } || 0
        pod_index = if service_folder_index > 0
                      service_folder_index - 1
                    else
                      service_folder_index
                    end
        path_components = path_components.drop(pod_index)
        path_components = path_components.delete_if { |e| %w[functional liveshots].include?(e) }

        path_components.each_with_index do |path_component, index|
          child_node = parent_node[path_component]
          unless child_node # if child node was not created yet
            if test_folder?(index, path_components)
              name = path_component.split('_').map(&:capitalize).join(' ')
              description = nil
              tags = []
              type = :SUITE
            else
              name = feature.name
              description = feature.file # TODO: consider adding feature description and comments
              tags = feature.tags.map(&:name)
              type = :TEST
            end

            if test_folder?(index, path_components) || type == :TEST
              item_key = "#{name}__index_#{index}__"
              lock_key = "#{item_key}.lock"

              id_of_created_item = redis_client.hget('report_portal', item_key)

              # id_of_created_item = ReportPortal.item_id_of(name, parent_node)

              if id_of_created_item.nil?

                acquired_lock = redis_client.hsetnx('report_portal', lock_key, Time.now.to_f.to_s)

                if acquired_lock
                  id_of_created_item = redis_client.hget('report_portal', item_key)

                  if id_of_created_item.nil?
                    item = ReportPortal::TestItem.new(
                      name: name,
                      type: type,
                      id: nil,
                      start_time: time_to_send(desired_time),
                      description: description,
                      closed: false,
                      tags: tags
                    )
                    child_node = Tree::TreeNode.new(path_component, item)
                    parent_node << child_node

                    item.id = ReportPortal.start_item(child_node) # TODO: multithreading
                    redis_client.hset('report_portal', item_key, item.id)
                  else
                    item = ReportPortal::TestItem.new(
                      name: name,
                      type: type,
                      id: id_of_created_item,
                      start_time: time_to_send(desired_time),
                      description: description,
                      closed: false,
                      tags: tags
                    )
                    child_node = Tree::TreeNode.new(path_component, item)
                    parent_node << child_node
                  end
                else
                  id_of_created_item = ::Poll.for(timeout: 10, retry_interval: 0.5, timeout_message: "Failed to get item id for #{name}") do
                    redis_client.hget('report_portal', item_key)
                  end

                  item = ReportPortal::TestItem.new(
                    name: name,
                    type: type,
                    id: id_of_created_item,
                    start_time: time_to_send(desired_time),
                    description: description,
                    closed: false,
                    tags: tags
                  )
                  child_node = Tree::TreeNode.new(path_component, item)
                  parent_node << child_node
                end
              else
                item = ReportPortal::TestItem.new(
                  name: name,
                  type: type,
                  id: id_of_created_item,
                  start_time: time_to_send(desired_time),
                  description: description,
                  closed: false,
                  tags: tags
                )
                child_node = Tree::TreeNode.new(path_component, item)
                parent_node << child_node
              end

            else # if not test folder
            item = ReportPortal::TestItem.new(
              name: name,
              type: type,
              id: nil,
              start_time: time_to_send(desired_time),
              description: description,
              closed: false,
              tags: tags
            )

            child_node = Tree::TreeNode.new(path_component, item)
            parent_node << child_node
            item.id = ReportPortal.start_item(child_node) # TODO: multithreading
            end
          end
          parent_node = child_node
        end
        @parent_item_node = child_node
      end

      def test_folder?(index, path_components)
        index < path_components.size - 1
      end

      # rubocop: enable Metrics/MethodLength
      # rubocop: enable Metrics/BlockLength
      # rubocop: enable Metrics/BlockNesting
      # rubocop: enable Metrics/AbcSize

      def end_feature(desired_time)
        ReportPortal.finish_item(@parent_item_node.content, nil, time_to_send(desired_time))
        # Folder items can't be finished here because when the folder started we didn't track
        #   which features the folder contains.
        # It's not easy to do it using Cucumber currently:
        #   https://github.com/cucumber/cucumber-ruby/issues/887
      end

      def close_all_children_of(root_node)
        root_node.postordered_each do |node|
          if !node.is_root? && !node.content.closed
            ReportPortal.finish_item(node.content)
          end
        end
      end

      def step?(test_step)
        !::Cucumber::Formatter::HookQueryVisitor.new(test_step).hook?
      end

      def report_hierarchy?
        !ReportPortal::Settings.instance.formatter_modes.include?('skip_reporting_hierarchy')
      end
    end
  end
end
# rubocop: enable Metrics/ClassLength
