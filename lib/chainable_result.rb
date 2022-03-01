class ChainableResult
  def initialize(source,method,args=nil,opts=nil,block=nil)
    @source = source
    @method = method
    @args = args
    @opts = opts
    @block = block
    @cached = false
  end

  def value
    if use_cache?
      return @value if @cached
      @cached = true
      @value = resolve_source.send(@method,*@args,**@opts,&@block)
    else
      resolve_source.send(@method,*@args,**@opts,&@block)
    end
  end

  def to_json(**opts)
    ChainableResult::Future.new(self,:to_json,[],opts)
  end

  def method_missing(method,*args,**opts,&block)
    ChainableResult::Future.new(self,method,args,opts,block)
  end

  class Future < self
    def resolve_source
      @source.value
    end
  end

  class Array < self
    def resolve_source
      @source.map &RESOLVE_ITEM
    end
  end

  class Hash < self
    def resolve_source
      @source.transform_values &RESOLVE_ITEM
    end
  end

  class Other < self
    def resolve_source
      @source
    end
  end

  def self.wrap(v,method=nil,*args,**opts,&block)
    method ||= block ? :then : :itself
    klass = case v
    when ChainableResult then return v # don't wrap, exit early
    when ::Array then ChainableResult::Array
    when ::Hash then ChainableResult::Hash
    else ChainableResult::Other
    end
    klass.new(v,method,args,opts,block)
  end

  def self.with(*results,&block)
    ChainableResult.wrap(1 == results.size ? results.first : results,:then,&block)
  end

  WITH = method(:with)

  def self.resolve_item(item)
    case item
    when ChainableResult then item.value
    when ::Array then ChainableResult::Array.new(item).value
    when ::Hash then ChainableResult::Hash.new(item).value
    else item
    end
  end

  RESOLVE_ITEM = method(:resolve_item)
  CACHE_MODE_KEY = :"ChainableResult::USE_CACHE"

  def self.with_cache(mode=true)
    prev = Thread.current[CACHE_MODE_KEY]
    Thread.current[CACHE_MODE_KEY] = mode
    result = yield
    Thread.current[CACHE_MODE_KEY] = prev
    result
  end

  private
  def use_cache?
    !!Thread.current[CACHE_MODE_KEY]
  end
end