require 'test_helper'

class TestRedis < Minitest::Test
  ERROR_TIMEOUT = 5
  ERROR_THRESHOLD = 1
  SEMIAN_OPTIONS = {
    name: :testing,
    tickets: 1,
    timeout: 0,
    error_threshold: ERROR_THRESHOLD,
    success_threshold: 2,
    error_timeout: ERROR_TIMEOUT,
  }

  attr_writer :threads
  def setup
    @proxy = Toxiproxy[:semian_test_redis]
    Semian.destroy(:redis_testing)
  end

  def test_semian_identifier
    assert_equal :redis_foo, new_redis(semian: {name: 'foo'}).client.semian_identifier
    assert_equal :'redis_127.0.0.1:16379/1', new_redis(semian: {name: nil}).client.semian_identifier
    assert_equal :'redis_example.com:42/1', new_redis(host: 'example.com', port: 42, semian: {name: nil}).client.semian_identifier
  end

  def test_client_alias
    redis = connect_to_redis!
    assert_equal redis.client.semian_resource, redis.semian_resource
    assert_equal redis.client.semian_identifier, redis.semian_identifier
  end

  def test_semian_can_be_disabled
    resource = Redis.new(semian: false).client.semian_resource
    assert_instance_of Semian::UnprotectedResource, resource
  end

  def test_semian_resource_in_pipeline
    redis = connect_to_redis!
    redis.pipelined do
      assert_instance_of Semian::ProtectedResource, redis.semian_resource
    end
  end

  def test_connection_errors_open_the_circuit
    client = connect_to_redis!

    @proxy.downstream(:latency, latency: 600).apply do
      ERROR_THRESHOLD.times do
        assert_raises ::Redis::TimeoutError do
          client.get('foo')
        end
      end

      assert_raises ::Redis::CircuitOpenError do
        client.get('foo')
      end
    end
  end

  def test_command_errors_does_not_open_the_circuit
    client = connect_to_redis!
    client.hset('my_hash', 'foo', 'bar')
    (ERROR_THRESHOLD * 2).times do
      assert_raises Redis::CommandError do
        client.get('my_hash')
      end
    end
  end

  def test_connect_instrumentation
    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true
      assert_equal :success, event
      assert_equal Semian[:redis_testing], resource
      assert_equal :connection, scope
      assert_equal :redis, adapter
    end

    connect_to_redis!

    assert notified, 'No notifications has been emitted'
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_connect
    connect_to_redis!

    Semian[:redis_testing].acquire do
      error = assert_raises Redis::ResourceBusyError do
        connect_to_redis!
      end
      assert_equal :redis_testing, error.semian_identifier
    end
  end

  def test_redis_connection_errors_are_tagged_with_the_resource_identifier
    @proxy.downstream(:latency, latency: 600).apply do
      error = assert_raises ::Redis::TimeoutError do
        connect_to_redis!
      end
      assert_equal :redis_testing, error.semian_identifier
    end
  end

  def test_other_redis_errors_are_not_tagged_with_the_resource_identifier
    client = connect_to_redis!
    client.set('foo', 'bar')
    error = assert_raises ::Redis::CommandError do
      client.hget('foo', 'bar')
    end
    refute error.respond_to?(:semian_identifier)
  end

  def test_resource_timeout_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_redis! }

      assert_raises Redis::ResourceBusyError do
        connect_to_redis!
      end
    end
  end

  def test_circuit_breaker_on_connect
    @proxy.downstream(:latency, latency: 500).apply do
      background { connect_to_redis! }

      ERROR_THRESHOLD.times do
        assert_raises Redis::ResourceBusyError do
          connect_to_redis!
        end
      end
    end

    yield_to_background

    assert_raises Redis::CircuitOpenError do
      connect_to_redis!
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      connect_to_redis!
    end
  end

  def test_query_instrumentation
    client = connect_to_redis!

    notified = false
    subscriber = Semian.subscribe do |event, resource, scope, adapter|
      notified = true
      assert_equal :success, event
      assert_equal Semian[:redis_testing], resource
      assert_equal :query, scope
      assert_equal :redis, adapter
    end

    client.get('foo')

    assert notified, 'No notifications has been emitted'
  ensure
    Semian.unsubscribe(subscriber)
  end

  def test_resource_acquisition_for_query
    client = connect_to_redis!

    Semian[:redis_testing].acquire do
      assert_raises Redis::ResourceBusyError do
        client.get('foo')
      end
    end
  end

  def test_resource_timeout_on_query
    client = connect_to_redis!
    client2 = connect_to_redis!

    @proxy.downstream(:latency, latency: 500).apply do
      background { client2.get('foo') }

      assert_raises Redis::ResourceBusyError do
        client.get('foo')
      end
    end
  end

  def test_circuit_breaker_on_query
    client = connect_to_redis!
    client2 = connect_to_redis!

    client.set('foo', 2)

    @proxy.downstream(:latency, latency: 1000).apply do
      background { client2.get('foo') }

      ERROR_THRESHOLD.times do
        assert_raises Redis::ResourceBusyError do
          client.get('foo')
        end
      end
    end

    yield_to_background

    assert_raises Redis::CircuitOpenError do
      client.get('foo')
    end

    Timecop.travel(ERROR_TIMEOUT + 1) do
      assert_equal '2', client.get('foo')
    end
  end

  private

  def new_redis(options = {})
    semian_options = SEMIAN_OPTIONS.merge(options.delete(:semian) || {})
    Redis.new({
      host: '127.0.0.1',
      port: 16_379,
      reconnect_attempts: 0,
      db: 1,
      timeout: 0.5,
      semian: semian_options,
    }.merge(options))
  end

  def connect_to_redis!(semian_options = {})
    redis = new_redis(semian: semian_options)
    redis.client.connect
    redis
  end
end
