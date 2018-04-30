# encoding: utf-8

require 'promise/version'

class Promise
  Error = Class.new(RuntimeError)
  BrokenError = Class.new(Error)

  def initialize
    @state = :pending
    @resolve = Proc.new if block_given?
  end

  def pending?
    defined?(@followee) ? @followee.pending? : @state.equal?(:pending)
  end

  def fulfilled?
    defined?(@followee) ? @followee.fulfilled? : @state.equal?(:fulfilled)
  end

  def rejected?
    defined?(@followee) ? @followee.rejected? : @state.equal?(:rejected)
  end

  def value
    defined?(@followee) ? @followee.value : @value
  end

  def reason
    defined?(@followee) ? @followee.reason : @reason
  end

  def state
    defined?(@followee) ? @followee.state : @state
  end

  def wait
    if defined?(@followee)
      @followee.wait
    elsif @resolve
      resolve, @resolve = @resolve, nil
      resolve.call(self)
    end
  rescue
    binding.pry
  end

  def self.sync(value)
    value.is_a?(Promise) ? value.sync : value
  end

  def self.resolve(value)
    value.is_a?(Promise) ? value : Promise.new.fulfill(value)
  end

  def self.all(promises)
    Promise.new do |p|
      begin
        result = promises.map do |promise_or_value|
          if promise_or_value.is_a?(Promise)
            promise_or_value.sync
          else
            promise_or_value
          end
        end
      rescue => err
        p.reject(err)
      else
        p.fulfill(result)
      end
    end
  end

  def sync
    wait if pending?

    raise BrokenError.new if pending?
    raise reason if rejected?
    return value
  end

  def then(on_fulfill = nil, on_reject = nil)
    on_fulfill ||= Proc.new if block_given?
    return self if on_fulfill.nil? && on_reject.nil?

    case state
    when :fulfilled
      Promise.new.promise_fulfilled(value, on_fulfill)
    when :rejected
      Promise.new.promise_rejected(reason, on_reject)
    else
      Promise.new do |p|
        wait if pending?

        begin
          maybe_promise = if fulfilled?
            on_fulfill.nil? ? value : on_fulfill.call(value)
          else
            on_reject.nil? ? reason : on_reject.call(reason)
          end

          value = maybe_promise.is_a?(Promise) ? maybe_promise.sync : maybe_promise
        rescue => err
          p.reject(err)
        else
          p.fulfill(value)
        end
      end
    end
  end

  def rescue(&block)
    self.then(nil, block)
  end
  alias_method :catch, :rescue

  def fulfill(value)
    return self if resolved?

    if value.is_a?(Promise)
      case value.state
      when :fulfilled
        fulfill(value.value)
      when :rejected
        reject(value.reason)
      else
        @followee = value
      end
    else
      @value = value
      @state = :fulfilled
    end

    self
  end

  def reject(reason)
    return self if resolved?

    @reason = reason
    @state = :rejected

    self
  end

  def resolved?
    defined?(@followee) || !pending?
  end

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

  def settle_from_handler(value)
    fulfill(yield(value))
  rescue => ex
    reject(ex)
  end
end
