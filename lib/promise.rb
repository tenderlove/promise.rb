# encoding: utf-8

require 'promise/version'

require 'promise/observer'
require 'promise/progress'
require 'promise/group'

class Promise
  Error = Class.new(RuntimeError)
  BrokenError = Class.new(Error)

  include Promise::Progress
  include Promise::Observer

  class Queue
    def initialize
      @microtasks = []
      @macrotasks = []
    end

    def enqueue_microtask(object, method, args = nil)
      @microtasks << object << method << args
    end

    def enqueue_macrotask(object, method, args = nil)
      @macrotasks << object << method << args
    end

    def run_once
      if @microtasks.length > 0
        args = @microtasks.pop
        method = @microtasks.pop
        object = @microtasks.pop
        args ? object.send(method, *args) : object.send(method)

        true
      elsif @macrotasks.length > 0
        args = @macrotasks.pop
        method = @macrotasks.pop
        object = @macrotasks.pop
        args ? object.send(method, *args) : object.send(method)

        true
      else
        false
      end
    end

    def run
      loop do
        break unless run_once
      end
    end

    def run_until_resolved(promise)
      while promise.pending?
        break unless run_once
      end
    end
  end

  QUEUE = Queue.new

  attr_reader :state, :value, :reason
  attr_accessor :async_guaranteed

  def self.resolve(obj = nil)
    return obj if obj.is_a?(self)
    new.tap { |promise| promise.fulfill(obj) }
  end

  def self.all(enumerable)
    Group.new(new, enumerable).promise
  end

  def self.map_value(obj)
    if obj.is_a?(Promise)
      obj.then { |value| yield value }
    else
      yield obj
    end
  end

  def self.sync(obj)
    obj.is_a?(Promise) ? obj.sync : obj
  end

  def initialize
    @state = :pending
    @async_guaranteed = false
  end

  def pending?
    state.equal?(:pending)
  end

  def fulfilled?
    state.equal?(:fulfilled)
  end

  def rejected?
    state.equal?(:rejected)
  end

  def then(on_fulfill = nil, on_reject = nil, &block)
    on_fulfill ||= block
    next_promise = self.class.new

    case state
    when :fulfilled
      QUEUE.enqueue_microtask(next_promise, :promise_fulfilled, [value, on_fulfill])
    when :rejected
      QUEUE.enqueue_microtask(next_promise, :promise_rejected, [reason, on_reject])
    else
      subscribe(next_promise, on_fulfill, on_reject)
    end

    next_promise
  end

  def rescue(&block)
    self.then(nil, block)
  end
  alias_method :catch, :rescue

  def sync
    QUEUE.run_until_resolved(self) if pending?
    raise BrokenError if pending?
    raise reason if rejected?
    value
  end

  def fulfill(value = nil)
    return self unless pending?

    if value.is_a?(Promise)
      case value.state
      when :fulfilled
        fulfill(value.value)
      when :rejected
        reject(value.reason)
      else
        value.subscribe(self, nil, nil)
      end
    else
      @state = :fulfilled
      @value = value

      if defined?(@observers)
        if @async_guaranteed
          notify_fulfillment
        else
          QUEUE.enqueue_microtask(self, :notify_fulfillment)
        end
      end
    end

    self
  end

  def reject(reason = nil)
    return self unless pending?

    @state = :rejected
    @reason = reason_coercion(reason || Error)

    if defined?(@observers)
      if @async_guaranteed
        notify_rejection
      else
        QUEUE.enqueue_microtask(self, :notify_rejection) if defined?(@observers)
      end
    end

    self
  end

  # Subscribe the given `observer` for status changes of a `Promise`.
  #
  # The observer will be notified about state changes of the promise
  # by calls to its `#promise_fulfilled` or `#promise_rejected` methods.
  #
  # These methods will be called with two arguments,
  # the first being the observed `Promise`, the second being the
  # `on_fulfill_arg` or `on_reject_arg` given to `#subscribe`.
  #
  # @param [Promise::Observer] observer
  # @param [Object] on_fulfill_arg
  # @param [Object] on_reject_arg
  def subscribe(observer, on_fulfill_arg, on_reject_arg)
    raise Error, 'Non-pending promises can not be observed' unless pending?

    unless observer.is_a?(Observer)
      raise ArgumentError, 'Expected `observer` to be a `Promise::Observer`'
    end

    @observers ||= []
    @observers.push(observer, on_fulfill_arg, on_reject_arg)
  end

  protected

  def promise_fulfilled(value, on_fulfill)
    if on_fulfill
      settle_from_handler(value, &on_fulfill)
    else
      fulfill(value)
    end
  end

  def promise_rejected(reason, on_reject)
    if on_reject
      settle_from_handler(reason, &on_reject)
    else
      reject(reason)
    end
  end

  private

  def reason_coercion(reason)
    case reason
    when Exception
      reason.set_backtrace(caller) unless reason.backtrace
    when Class
      reason = reason_coercion(reason.new) if reason <= Exception
    end
    reason
  end

  def notify_fulfillment
    @observers.each_slice(3) do |observer, on_fulfill_arg|
      observer.promise_fulfilled(value, on_fulfill_arg)
    end

    @observers = nil
  end

  def notify_rejection
    @observers.each_slice(3) do |observer, _on_fulfill_arg, on_reject_arg|
      observer.promise_rejected(reason, on_reject_arg)
    end

    @observers = nil
  end

  def settle_from_handler(value)
    fulfill(yield(value))
  rescue => ex
    reject(ex)
  end
end
