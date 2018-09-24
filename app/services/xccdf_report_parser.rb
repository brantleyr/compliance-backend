# frozen_string_literal: true

require 'openscap'
require 'openscap/source'
require 'openscap/xccdf'
require 'openscap/xccdf/benchmark'
require 'openscap/xccdf/testresult'

# Takes in a path to an XCCDF file, returns all kinds of properties about it
# and saves it in our database
class XCCDFReportParser
  def initialize(report_path)
    @report_path = report_path
    @source = ::OpenSCAP::Source.new(report_path)
    @benchmark = ::OpenSCAP::Xccdf::Benchmark.new(@source)
  end

  def test_result
    return @test_result if @test_result.present?

    xccdf_report = File.open(@report_path) { |f| Nokogiri::XML(f) }
    source = ::OpenSCAP::Source.new(
      content: create_test_result(xccdf_report).to_xml
    )
    begin
      @test_result = ::OpenSCAP::Xccdf::TestResult.new(source)
    rescue ::OpenSCAP::OpenSCAPError => e
      Rails.logger.error('Error: ', e)
    end
  end

  def score
    test_result.score['urn:xccdf:scoring:default'][:value]
  end

  def profiles
    result = {}
    @benchmark.profiles.each do |id, oscap_profile|
      result[id] = oscap_profile.title
    end
    result
  end

  def save_profiles
    created = []
    profiles.each do |ref_id, name|
      if (profile = Profile.find_by(:name => name, :ref_id => ref_id))
        created << profile
        next
      end
      created << Profile.create(:name => name, :ref_id => ref_id)
    end
    created
  end

  def rule_ids
    test_result.rr.keys
  end

  def save_rules
    new_rules = []
    rules = @benchmark.items.find_all { |k,v| v.is_a?(OpenSCAP::Xccdf::Rule) }
    rules.each do |rule|
      ref_id = rule[0]
      rule_object = rule[1]
      rationale = rule_object.rationale
      description = rule_object.description
      title = rule_object.title
      severity = rule_object.severity
      new_rules << Rule.create(
        :ref_id => ref_id,
        :rationale => rationale,
        :description => description,
        :title => title,
        :severity => severity
      )
    end
    new_rules
  end

  private

  def find_namespace(report_xml)
    report_xml.namespaces['xmlns']
  end

  def create_test_result(report_xml)
    test_result_node = report_xml.search('TestResult')
    test_result_doc = Nokogiri::XML::Document.parse(test_result_node.to_xml)
    test_result_doc.root.default_namespace = find_namespace(report_xml)
    test_result_doc.namespace = test_result_doc.root.namespace
    test_result_doc
  end
end