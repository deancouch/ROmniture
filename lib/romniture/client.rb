module ROmniture
  
  class Client

    DEFAULT_REPORT_WAIT_TIME = 0.25
    
    ENVIRONMENTS = {
      :san_jose       => "https://api.omniture.com/admin/1.4/rest/",
      :dallas         => "https://api2.omniture.com/admin/1.4/rest/",
      :london         => "https://api3.omniture.com/admin/1.4/rest/",
      :san_jose_beta  => "https://beta-api.omniture.com/admin/1.4/rest/",
      :dallas_beta    => "https://beta-api2.omniture.com/admin/1.4/rest/",
      :sandbox        => "https://api-sbx1.omniture.com/admin/1.4/rest/"
    }    
    
    def initialize(username, shared_secret, environment, options={})
      @username       = username
      @shared_secret  = shared_secret
      @environment    = environment.is_a?(Symbol) ? ENVIRONMENTS[environment] : environment.to_s

      @wait_time      = options[:wait_time] ? options[:wait_time] : DEFAULT_REPORT_WAIT_TIME
      @log            = options[:log] ? options[:log] : false
      @verify_mode    = options[:verify_mode] ? options[:verify_mode] : false
      HTTPI.log       = false
    end
        
    def request(method, parameters = {})
      response = send_request(method, parameters)

      begin
        JSON.parse(response.body)
      rescue JSON::ParserError => pe
        response.body
      rescue Exception => e
        log(Logger::ERROR, "Error in request response:\n#{response.body}")
        raise "Error in request response:\n#{response.body}"
      end
    end
    
    def get_report(method, report_description)
      response = send_request(method, report_description)
      
      json = JSON.parse response.body
      if json["reportID"]
        log(Logger::INFO, "Report with ID (" + json["reportID"].to_s + ") queued.  Now fetching report...")
        return get_queued_report json["reportID"]
      else
        log(Logger::ERROR, "Could not queue report.  Omniture returned with error:\n#{response.body}")
        raise "Could not queue report.  Omniture returned with error:\n#{response.body}"
      end
    end
    
    def get_queued_report(report_id)
      try_again = false
      error = false
      done = false
      end_time = nil
      start_time = Time.now

      begin
        error = false
        try_again = false

        response = send_request("Report.Get", { "reportID" => "#{report_id}" })
        
        json = JSON.parse(response.body)

        if response.code == 200
          done = true
        else
          error = true
          log(Logger::WARN, "#{json['error']}: #{json["error_description"]}")
          try_again = response.code == 400 && json["error"] == "report_not_ready"
        end
        
        sleep @wait_time if try_again && !done
      end while try_again && !done
      
      if error
        msg = "Unable to get data for report #{report_id}. Error Code: #{json["error"]}."
        log(Logger::ERROR, msg)
        raise ROmniture::Exceptions::OmnitureReportException.new(json), msg
      end

      end_time = Time.now
      log(Logger::INFO, "Report with ID #{report_id} has finished processing in #{((end_time - start_time)*1000).to_i} ms")
      
      JSON.parse(response.body)
    end

    attr_writer :log
    
    def log?
      @log != false
    end
    
    def logger
      @logger ||= ::Logger.new(STDOUT)
    end
    
    def log_level
      @log_level ||= ::Logger::INFO
    end
    
    def log(*args)
      level = args.first.is_a?(Numeric) || args.first.is_a?(Symbol) ? args.shift : log_level
      logger.log(level, args.join(" ")) if log?
    end
        
    private
    
    def send_request(method, data)
      log(Logger::INFO, "Requesting #{method}...")
      generate_nonce
      
      log(Logger::INFO, "Created new nonce: #{@password}")
      
      request = HTTPI::Request.new

      if @verify_mode
        request.auth.ssl.verify_mode = @verify_mode
      end

      request.url = @environment + "?method=#{method}"
      request.headers = request_headers
      request.body = data.to_json

      response = HTTPI.post(request)

      log(Logger::INFO, "Server responded with response code #{response.code}.")

      response
    end
    
    def generate_nonce
      @nonce          = Digest::MD5.new.hexdigest(rand().to_s)
      @created        = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      combined_string = @nonce + @created + @shared_secret
      sha1_string     = Digest::SHA1.new.hexdigest(combined_string)
      @password       = Base64.encode64(sha1_string).to_s.chomp("\n")
    end    

    def request_headers 
      {
        "X-WSSE" => "UsernameToken Username=\"#{@username}\", PasswordDigest=\"#{@password}\", Nonce=\"#{@nonce}\", Created=\"#{@created}\""
      }
    end
  end
end
