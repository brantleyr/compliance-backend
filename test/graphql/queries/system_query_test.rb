# frozen_string_literal: true

require 'test_helper'

class SystemQueryTest < ActiveSupport::TestCase
  setup do
    users(:test).update account: accounts(:test)
    hosts(:one).update account: accounts(:test)
  end

  test 'query host owned by the user' do
    query = <<-GRAPHQL
      query System($inventoryId: String!){
          system(id: $inventoryId) {
              name
          }
      }
    GRAPHQL

    result = Schema.execute(
      query,
      variables: { inventoryId: hosts(:one).id },
      context: { current_user: users(:test) }
    )

    assert_equal hosts(:one).name, result['data']['system']['name']
  end

  test 'query host owned by another user' do
    query = <<-GRAPHQL
      query System($inventoryId: String!){
          system(id: $inventoryId) {
              name
          }
      }
    GRAPHQL

    hosts(:one).update account: accounts(:test)
    users(:test).update account: nil

    assert_raises(Pundit::NotAuthorizedError) do
      Schema.execute(
        query,
        variables: { inventoryId: hosts(:one).id },
        context: { current_user: users(:test) }
      )
    end
  end

  test 'some host attributes can be queried without profileId arguments' do
    query = <<-GRAPHQL
    {
        allSystems(perPage: 50, page: 1) {
            id
            name
            profileNames
            compliant
            rulesPassed
            rulesFailed
            lastScanned
        }
    }
    GRAPHQL

    profiles(:one).rules << rules(:one)
    profiles(:two).rules << rules(:two)
    hosts(:one).profiles << profiles(:one)
    hosts(:one).profiles << profiles(:two)
    test_results(:one).update(profile: profiles(:one), host: hosts(:one))
    test_results(:two).update(profile: profiles(:two), host: hosts(:one))

    result = Schema.execute(
      query,
      variables: {},
      context: { current_user: users(:test) }
    )

    assert_equal "#{profiles(:one).name}, #{profiles(:two).name}",
                 result['data']['allSystems'].first['profileNames']
    assert_not result['data']['allSystems'].first['compliant']
  end

  test 'query attributes with profileId arguments' do
    query = <<-GRAPHQL
    query getSystems($policyId: String) {
        allSystems(perPage: 50, page: 1, profileId: $policyId) {
            id
            name
            rulesPassed(profileId: $policyId)
            rulesFailed(profileId: $policyId)
            lastScanned(profileId: $policyId)
            compliant(profileId: $policyId)
        }
    }
    GRAPHQL

    rule_results(:one).update(
      host: hosts(:one), rule: rules(:one), test_result: test_results(:one)
    )
    rule_results(:two).update(
      host: hosts(:one), rule: rules(:two), test_result: test_results(:two)
    )
    test_results(:one).update(profile: profiles(:one), host: hosts(:one))
    test_results(:two).update(profile: profiles(:two), host: hosts(:one))
    profiles(:one).rules << rules(:one)
    profiles(:two).rules << rules(:two)
    hosts(:one).profiles << profiles(:one)
    hosts(:one).profiles << profiles(:two)

    result = Schema.execute(
      query,
      variables: { policyId: profiles(:one).id },
      context: { current_user: users(:test) }
    )

    assert_equal 1, result['data']['allSystems'].first['rulesPassed']
    assert_equal 0, result['data']['allSystems'].first['rulesFailed']
    assert result['data']['allSystems'].first['lastScanned']
    assert result['data']['allSystems'].first['compliant']
  end

  test 'query children profile only returns profiles owned by host' do
    query = <<-GRAPHQL
    query getSystems {
        systems {
            edges {
                node {
                    id
                    name
                    profiles {
                        id
                        name
                        rulesPassed
                        rulesFailed
                        lastScanned
                        compliant
                    }
                }
            }
        }
    }
    GRAPHQL

    setup_two_hosts
    result = Schema.execute(
      query,
      context: { current_user: users(:test) }
    )

    hosts = result['data']['systems']['edges']
    assert_equal 2, hosts.count
    hosts.each do |graphql_host|
      host = Host.find(graphql_host['node']['id'])
      graphql_host['node']['profiles'].each do |graphql_profile|
        assert host.profiles.map(&:name).include? graphql_profile['name']
        profile = Profile.find(graphql_profile['id'])
        assert_equal host.rules_passed(profile), graphql_profile['rulesPassed']
        assert_equal host.rules_failed(profile), graphql_profile['rulesFailed']
      end
    end
  end

  test 'page info can be obtained on system query' do
    query = <<-GRAPHQL
    query getSystems($first: Int) {
        systems(first: $first) {
            totalCount,
            pageInfo {
                hasNextPage
                hasPreviousPage
                startCursor
                endCursor
            }
            edges {
                node {
                    id
                    name
                }
            }
        }
    }
    GRAPHQL

    setup_two_hosts
    result = Schema.execute(
      query,
      variables: { first: 1 },
      context: { current_user: users(:test) }
    )['data']

    assert_equal false, result['systems']['pageInfo']['hasPreviousPage']
    assert_equal true, result['systems']['pageInfo']['hasNextPage']
  end

  test 'limit and offset paginate the query' do
    query = <<-GRAPHQL
    query getSystems($perPage: Int, $page: Int) {
        systems(limit: $perPage, offset: $page) {
            totalCount,
            edges {
                node {
                    id
                    name
                }
            }
        }
    }
    GRAPHQL

    setup_two_hosts
    result = Schema.execute(
      query,
      variables: { perPage: 1, page: 1 },
      context: { current_user: users(:test) }
    )['data']

    assert_equal users(:test).account.hosts.count,
                 result['systems']['totalCount']
    assert_equal 1, result['systems']['edges'].count
  end

  test 'search is applied to results and total count refers to search' do
    query = <<-GRAPHQL
    query getSystems($search: String) {
        systems(search: $search) {
            totalCount
            edges {
                node {
                    id
                    name
                }
            }
        }
    }
    GRAPHQL
    setup_two_hosts
    result = Schema.execute(
      query,
      variables: { search: "profile_id = #{profiles(:one).id}" },
      context: { current_user: users(:test) }
    )['data']
    graphql_host = Host.find(result['systems']['edges'].first['node']['id'])
    assert_not_equal users(:test).account.hosts.count,
                     result['systems']['totalCount']
    assert_equal 1, result['systems']['totalCount']
    assert graphql_host.profiles.pluck(:id).include?(profiles(:one).id)
  end

  private

  # rubocop:disable AbcSize
  # rubocop:disable MethodLength
  def setup_two_hosts
    hosts(:one).profiles << profiles(:one)
    hosts(:two).profiles << profiles(:two)
    rule_results(:one).update(
      host: hosts(:one), rule: rules(:one), test_result: test_results(:one)
    )
    rule_results(:two).update(
      host: hosts(:two), rule: rules(:two), test_result: test_results(:two)
    )
    test_results(:one).update(profile: profiles(:one), host: hosts(:one))
    test_results(:two).update(profile: profiles(:two), host: hosts(:two))
    profiles(:one).rules << rules(:one)
    profiles(:two).rules << rules(:two)
    hosts(:two).update(account: accounts(:test))
  end
  # rubocop:enable AbcSize
  # rubocop:enable MethodLength
end
