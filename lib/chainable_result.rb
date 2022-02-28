class ChainableResult
  def initialize(source,method,args=nil,opts=nil,block=nil)
    @source = source
    @method = method
    @args = args
    @opts = opts
    @block = block
  end

  def value
    resolve_source.send(@method,*@args,**@opts,&@block)
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
      @source.map do |item|
        next item.value if item.is_a? ChainableResult
        item
      end
    end
  end

  class Hash < self
    def resolve_source
      @source.transform_values do |item|
        next item.value if item.is_a? ChainableResult
        item
      end
    end
  end

  class Other < self
    def resolve_source
      @source
    end
  end

  def self.wrap(v,method,*args,**opts,&block)
    klass = case v
    when ChainableResult then v
    when ::Array then ChainableResult::Array
    when ::Hash then ChainableResult::Hash
    else v.respond_to?(:value) ? ChainableResult::Future : ChainableResult::Other
    end
    klass.new(v,method,args,opts,block)
  end
    
end