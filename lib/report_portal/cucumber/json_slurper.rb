# Copyright 2015 EPAM Systems
# 
# 
# This file is part of Report Portal.
# 
# Report Portal is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# ReportPortal is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
# 
# You should have received a copy of the GNU Lesser General Public License
# along with Report Portal.  If not, see <http://www.gnu.org/licenses/>.

require 'base64'
require 'securerandom'
require 'mime/types'

require_relative '../../reportportal'
require_relative '../settings'

module ReportPortal
  module Cucumber
    # Helper class to parse and post test launch data generated by Cucumber's JSON formatter
    # Supports ONLY reports generated with -x switch (i.e. expanded outlines)
    class JSONSlurper
      def initialize(filename)
        @json = JSON.parse(File.read(filename))
        fail "Cannot process #{filename} because it was generated without -x/--expand Cucumber option!" unless expanded?
        calculate_start_time
      end

      def run
        ReportPortal.start_launch('', get_time)

        @json.each do |feature|
          current_feature = ReportPortal::TestItem.new("Feature: #{feature['name']}",
                                                       :TEST,
                                                       nil,
                                                       get_time,
                                                       feature['uri'],
                                                       nil,
                                                       tags(feature))
          current_feature_node = Tree::TreeNode.new(SecureRandom.hex, current_feature)
          current_feature.id = ReportPortal.start_item(current_feature_node)
          current_element_name = nil
          current_outline_row = 0

          feature['elements'].each do |element|
            type = element['type'] == 'background' ? :BEFORE_CLASS : :STEP

            element_name = "#{element['keyword']}: #{element['name']}"
            if element['keyword'] == 'Scenario Outline'
              if element['name'] == current_element_name
                current_outline_row += 1
              else
                current_element_name = element['name']
                current_outline_row = 1
              end
              element_name << " [#{current_outline_row}]"
            end

            ReportPortal.current_scenario = ReportPortal::TestItem.new(element_name,
                                                                       type,
                                                                       nil,
                                                                       get_time,
                                                                       "#{feature['uri']}:#{element['line']}",
                                                                       nil,
                                                                       tags(element))
            current_scenario_node = Tree::TreeNode.new(SecureRandom.hex, ReportPortal.current_scenario)
            ReportPortal.current_scenario.id = ReportPortal.start_item(current_scenario_node)

            statuses = report_hooks(element, 'before')
            forced_issue = nil
            element['steps'].each do |step|
              name = decorate("#{step['keyword']}#{step['name']}")
              if step['rows']
                name << step['rows'].reduce("\n") { |acc, row| acc << decorate("| #{row['cells'].join(' | ')} |") << "\n" }
              end
              if step['doc_string']
                name << %(\n"""\n#{step['doc_string']['value']}\n""")
              end

              ReportPortal.send_log(:passed, name, get_time)
              step['output'].each { |o| ReportPortal.send_log(:passed, o, get_time) } unless step['output'].nil?
              error = step['result']['error_message']
              ReportPortal.send_log(:failed, error, get_time) if error
              (step['embeddings'] || []).each do |embedding|
                ReportPortal.send_file(:failed, embedding['data'], 'Embedding', get_time, embedding['mime_type'])
              end
              statuses << step['result']['status']
              forced_issue ||= case step['result']['status']
                               when 'pending'
                                 error
                               when 'undefined'
                                 "Undefined step #{step['name']} at #{step['match']['location']}"
                               else
                                 nil
                               end

              ReportPortal.send_log(step['result']['status'].to_sym,
                                    "STEP #{step['result']['status'].upcase}",
                                    get_time(step['result']['duration'].to_i / 1_000_000))
            end
            statuses += report_hooks(element, 'after')

            status = if statuses.any? { |s| %w(failed undefined pending).include? s }
                       :failed
                     elsif statuses.all? { |s| s == 'passed' }
                       :passed
                     else
                       :skipped
                     end

            ReportPortal.finish_item(ReportPortal.current_scenario, status, get_time, forced_issue)
            ReportPortal.current_scenario = nil
          end

          ReportPortal.finish_item(current_feature, nil, get_time)
        end
        ReportPortal.finish_item(root, nil, get_time)
        ReportPortal.finish_launch(get_time)
      end

      private

      def tags(item)
        item['tags'].nil? ? [] : item['tags'].map { |h| h['name'] }
      end

      def decorate(str)
        sep = '-' * 25
        "#{sep}#{str}#{sep}"
      end

      def expanded?
        bad_item = @json.find do |f|
          so = f['elements'].find { |e| e['keyword'] == 'Scenario Outline' }
          so ? so.key?('examples') : false
        end
        bad_item.nil?
      end

      def calculate_start_time
        duration_nanos = 0
        @json.each do |f|
          f['elements'].each do |e|
            items = e['steps'] + (e['before'] || []) + (e['after'] || [])
            items.each do |s|
              duration_nanos += s['result']['duration'].to_i
            end
          end
        end
        @now = (Time.now.to_f * 1000).to_i - (duration_nanos / 1_000_000)
      end

      # update current time and return
      def get_time(offset = 0)
        @now += offset + 1
      end

      # report before/after hooks and return array of their statuses
      def report_hooks(element, tag)
        (element[tag] || []).map do |hook|
          ReportPortal.send_log(hook['result']['status'].to_sym,
                                "HOOK #{hook['match']['location']} #{hook['result']['status'].upcase}",
                                get_time(hook['result']['duration'].to_i / 1_000_000))
          hook['result']['status']
        end
      end
    end
  end
end
