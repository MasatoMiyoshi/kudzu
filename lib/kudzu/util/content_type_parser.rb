module Kudzu
  class Util
    class ContentTypeParser
      def parse(content_type)
        mime, *kvs = content_type.to_s.split(';').map { |str| str.strip.downcase }
        params = kvs.each_with_object({}) do |kv, hash|
                   k, v = kv.to_s.split('=').map { |str| str.strip }
                   hash[k.to_sym] = unquote(v)
                 end
        return mime, params
      end

      private

      def unquote(str)
        if str =~ /^"(.*?)"$/
          $1.gsub(/\\(.)/, '\1')
        else
          str
        end
      end
    end
  end
end
