require 'addressable'
require 'nokogiri'
require_relative 'common'
require_relative 'configurable'
require_relative 'adapter/memory'
require_relative 'crawler/all'
require_relative 'revisit/all'
require_relative 'util/all'

module Kudzu
  class Crawler
    attr_reader :uuid, :dsl
    attr_reader :frontier, :repository

    def initialize(options = {}, &block)
      @dsl = DSL.new(options)
      @dsl.instance_eval(&block) if block
      @dsl.instance_eval(File.read(options[:config_file])) if options.key?(:config_file)

      @uuid = options[:uuid] || SecureRandom.uuid
      @config = dsl.config
    end

    def prepare(&block)
      @frontier = Kudzu.adapter::Frontier.new(@uuid)
      @repository = Kudzu.adapter::Repository.new(@config)

      @robots = Robots.new(@config)
      @page_fetcher = PageFetcher.new(@config, @robots)
      @page_filter = PageFilter.new(@config)
      @url_extractor = UrlExtractor.new(@config)
      @url_normalizer = UrlNormalizer.new(@config)
      @url_filter = UrlFilter.new(@config, @robots)
      @charset_detector = CharsetDetector.new

      @callback = Callback.new
      block.call(@callback) if block

      @revisit_scheduler = Revisit::Scheduler.new(@config)
      @content_type_parser = Util::ContentTypeParser.new

      if @config[:log_file]
        @logger = Logger.new(@config[:log_file])
        @logger.level = @config[:log_level]
      end
    end

    def run(seed_url, &block)
      prepare(&block)

      @frontier.enqueue(seed_url, depth: 1)

      if @config[:thread_num].to_i <= 1
        single_thread
      else
        multi_thread(@config[:thread_num])
      end

      @page_fetcher.pool.close
      @frontier.clear
    end

    private

    def single_thread
      loop do
        link = @frontier.dequeue.first
        break unless link
        visit_link(link)
      end
    end

    def multi_thread(thread_num)
      @thread_pool = Util::ThreadPool.new(thread_num)

      @thread_pool.start do |queue|
        limit_num = [thread_num - queue.size, 0].max
        @frontier.dequeue(limit: limit_num).each do |link|
          queue.push(link)
        end
        link = queue.pop
        visit_link(link)
      end

      @thread_pool.wait
      @thread_pool.shutdown
    end

    def visit_link(link)
      page = @repository.find_by_url(link.url)
      response = fetch_link(link, build_request_header(page))
      return unless response

      page.url = response.url
      page.status = response.status
      page.response_time = response.time
      page.fetched_at = Time.now

      if page.status_success?
        handle_success(page, link, response)
      elsif page.status_not_modified?
        @revisit_scheduler.schedule(page, modified: false)
        @repository.register(page)
      elsif page.status_not_found? || page.status_gone?
        @repository.delete(page)
      end

      run_callback(page, link)
    end

    def run_callback(page, link)
      if page.status_success?
        if page.filtered
          @callback.run(:on_filter, page, link)
        else
          @callback.run(:on_success, page, link)
        end
      elsif page.status_redirection?
        @callback.run(:on_redirection, page, link)
      elsif page.status_client_error?
        @callback.run(:on_client_error, page, link)
      elsif page.status_server_error?
        @callback.run(:on_server_error, page, link)
      end
    end

    def build_request_header(page)
      header = @config[:default_request_header].to_h
      if @config[:revisit_mode]
        header['If-Modified-Since'] = page.last_modified.httpdate if page.last_modified
        header['If-None-Match'] = page.etag if page.etag
      end
      header
    end

    def fetch_link(link, request_header)
      response = @page_fetcher.fetch(link.url, request_header)
      log :info, "page fetched: #{response.status} #{response.url}"
      response
    rescue Exception => e
      log :warn, "couldn't fetch page: #{link.url}", e
      @callback.run(:failure, link, e)
      nil
    end

    def handle_success(page, link, response)
      digest = Digest::MD5.hexdigest(response.body)
      @revisit_scheduler.schedule(page, modified: page.digest != digest)

      page.response_header = response.header
      page.mime_type = @content_type_parser.parse(response.header['content-type']).first
      page.body = response.body
      page.size = response.body.size
      page.digest = digest
      page.charset = detect_charset(page) if page.text?

      if follow_urls_from?(page, link)
        follow_urls = extract_urls(page)
        follow_urls = normalize_urls(follow_urls, page.url)
        follow_urls = filter_urls(follow_urls, page.url)
        @frontier.enqueue(follow_urls, depth: link.depth + 1)
      end

      if allowed_page?(page)
        @repository.register(page)
      else
        page.filtered = true
        @repository.delete(page)
      end
    end

    def detect_charset(page)
      @charset_detector.detect(page)
    rescue => e
      log :warn, "couldn't detect charset for #{page.url}", e
    end

    def follow_urls_from?(page, link)
      (page.html? || page.xml?) && (@config[:max_depth].nil? || link.depth < @config[:max_depth].to_i)
    end

    def extract_urls(page)
      @url_extractor.extract(page)
    rescue => e
      log :warn, "couldn't extract links from #{page.url}", e
    end

    def normalize_urls(urls, base_url)
      urls.map { |url| normalize_url(url, base_url) }.compact.uniq
    end

    def normalize_url(url, base_url)
      @url_normalizer.normalize(url, base_url)
    rescue => e
      log :warn, "couldn't normalize links for #{url}", e
      nil
    end

    def filter_urls(urls, base_url)
      passed, dropped = @url_filter.filter(urls, base_url)
      passed.each { |url| log :debug, "link passed: #{url}" }
      dropped.each { |url| log :debug, "link dropped: #{url}" }
      passed
    end

    def allowed_page?(page)
      if @page_filter.allowed?(page) && !@repository.exist_same_content?(page)
        log :info, "page passed: #{page.url}"
        true
      else
        log :info, "page dropped: #{page.url}"
        false
      end
    end

    def log(level, message, ex = nil)
      return unless @logger
      message += " #{ex.class} #{ex.message} #{ex.backtrace.join("\n")}" if ex
      @logger.send(level, message)
    end
  end
end
