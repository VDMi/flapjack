#!/usr/bin/env ruby

require 'chronic'
require 'chronic_duration'
require 'sinatra/base'
require 'tilt/erb'
require 'uri'

require 'flapjack/gateways/api_web/middleware/request_timestamp'

require 'flapjack-diner'

require 'flapjack/utility'

module Flapjack

  module Gateways

    class ApiWeb < Sinatra::Base

      set :root, File.dirname(__FILE__)

      use Flapjack::Gateways::ApiWeb::Middleware::RequestTimestamp
      use Rack::MethodOverride

      set :raise_errors, false
      set :protection, except: :path_traversal

      set :views, settings.root + '/api_web/views'
      set :public_folder, settings.root + '/api_web/public'

      set :erb, :layout => 'layout.html'.to_sym

      class << self
        def start
          Flapjack.logger.info "starting api_web - class"

          set :show_exceptions, false
          @show_exceptions = Sinatra::ShowExceptions.new(self)

          if access_log = (@config && @config['access_log'])
            unless File.directory?(File.dirname(access_log))
              raise "Parent directory for log file #{access_log} doesn't exist"
            end

            use Rack::CommonLogger, ::Logger.new(@config['access_log'])
          end

          # FIXME don't need an instance variable for @api_url any more
          @api_url = @config['api_url']
          if @api_url
            if URI.regexp(['http', 'https']).match(@api_url).nil?
              Flapjack.logger.error "api_url is not a valid http or https URI (#{@api_url}), discarding"
              @api_url = nil
              # FIXME raise error
            end
            unless @api_url.match(/^.*\/$/)
              Flapjack.logger.info "api_url must end with a trailing '/', setting to '#{@api_url}/'"
              @api_url = "#{@api_url}/"
            end
          else
            # FIXME raise error
          end

          Flapjack::Diner.base_uri(@api_url) unless @api_url.nil?
          Flapjack::Diner.logger = ::Logger.new('log/flapjack_diner.log')

          # constants won't be exposed to eRb scope
          @default_logo_url = "img/flapjack-2013-notext-transparent-300-300.png"
          @logo_image_file  = nil
          @logo_image_ext   = nil

          if logo_image_path = @config['logo_image_path']
            if File.file?(logo_image_path)
              @logo_image_file = logo_image_path
              @logo_image_ext  = File.extname(logo_image_path)
            else
              Flapjack.logger.error "logo_image_path '#{logo_image_path}'' does not point to a valid file."
            end
          end

          @auto_refresh = (@config['auto_refresh'].respond_to?('to_i') &&
                           (@config['auto_refresh'].to_i > 0)) ? @config['auto_refresh'].to_i : false
        end
      end

      include Flapjack::Utility

      helpers do
        def h(text)
          ERB::Util.h(text)
        end

        def u(text)
          ERB::Util.u(text)
        end

        def include_active?(path)
          return '' unless request.path == "/#{path}"
          " class='active'"
        end

        def charset_for_content_type(ct)
          charset = Encoding.default_external
          charset.nil? ? ct : "#{ct}; charset=#{charset.name}"
        end
      end

      ['config'].each do |class_inst_var|
        define_method(class_inst_var.to_sym) do
          self.class.instance_variable_get("@#{class_inst_var}")
        end
      end

      before do
        content_type charset_for_content_type('text/html')

        @api_url          = self.class.instance_variable_get('@api_url')
        @base_url         = "#{request.base_url}/"
        @default_logo_url = self.class.instance_variable_get('@default_logo_url')
        @logo_image_file  = self.class.instance_variable_get('@logo_image_file')
        @logo_image_ext   = self.class.instance_variable_get('@logo_image_ext')
        @auto_refresh     = self.class.instance_variable_get('@auto_refresh')

        input = nil
        query_string = (request.query_string.respond_to?(:length) &&
        request.query_string.length > 0) ? "?#{request.query_string}" : ""
        if Flapjack.logger.debug?
          input = env['rack.input'].read
          Flapjack.logger.debug("#{request.request_method} #{request.path_info}#{query_string} #{input}")
        elsif Flapjack.logger.info?
          input = env['rack.input'].read
          input_short = input.gsub(/\n/, '').gsub(/\s+/, ' ')
          Flapjack.logger.info("#{request.request_method} #{request.path_info}#{query_string} #{input_short[0..80]}")
        end
        env['rack.input'].rewind unless input.nil?
      end

      get '/img/branding.*' do
        halt(404) unless @logo_image_file && params[:splat].first.eql?(@logo_image_ext[1..-1])
        send_file(@logo_image_file)
       end

      get '/' do
        @metrics = Flapjack::Diner.metrics

        erb 'index.html'.to_sym
      end

      get '/self_stats' do
        @current_time = Time.now

        @metrics   = Flapjack::Diner.metrics
        statistics = Flapjack::Diner.statistics

        unless statistics.nil?
          @executive_instances = statistics.each_with_object({}) do |stats, memo|
            if 'global'.eql?(stats[:instance_name])
              @global_stats = stats
              next
            end
            boot_time =  Time.parse(stats[:created_at])
            uptime = @current_time - boot_time
            uptime_string = ChronicDuration.output(uptime, :format => :short,
                              :keep_zero => true, :units => 2) || '0s'

            event_counters = {}
            event_rates    = {}

            [:all_events, :ok_events, :failure_events, :action_events,
             :invalid_events].each do |evt|

              count               = stats[evt]
              event_counters[evt] = count
              event_rates[evt]    = (uptime > 0) ? (count.to_f / uptime).round : nil
            end

            memo[stats[:instance_name]] = {
              :uptime         => uptime,
              :uptime_string  => uptime_string,
              :event_counters => event_counters,
              :event_rates    => event_rates
            }
          end
        end

        erb 'self_stats.html'.to_sym
      end

      get '/tags' do
        opts = {}
        @name = params[:name]
        opts.update(:name => @name) unless @name.nil? || @name.empty?

        @tags = Flapjack::Diner.tags(:filter => opts,
          :page => (params[:page] || 1))

        erb 'tags.html'.to_sym
      end

      get '/tags/:name' do
        tag_name = params[:name]

        @tag = Flapjack::Diner.tags(tag_name)
        err(404, "Could not find tag '#{tag_name}'") if @tag.nil?

        check_ids = Flapjack::Diner.tag_link_checks(tag_name)
        err(404, "Could not find checks for tag '#{tag_name}'") if check_ids.nil?

        erb 'tag.html'.to_sym
      end

      get '/checks' do
        time = Time.now

        opts = {}

        @name = params[:name]
        opts.update(:name => @name) unless @name.nil? || @name.empty?

        @enabled = boolean_from_str(params[:enabled])
        opts.update(:enabled => @enabled) unless @enabled.nil?

        @failing = boolean_from_str(params[:failing])
        opts.update(:failing => @failing) unless @failing.nil?

        @checks = Flapjack::Diner.checks(:filter => opts,
                    :page => (params[:page] || 1),
                    :include => [:current_state, :latest_notifications])

        unless @checks.nil?
          @pagination = pagination_from_context(Flapjack::Diner.context)
          unless @pagination.nil?
            @links = create_pagination_links(@pagination[:page],
              @pagination[:total_pages])
          end
        end

        @states = {}

    #     @states = @checks.inject({}) do |memo, check|
    #       memo[check] = check_state(check, time)
    #       memo
    #     end

        erb 'checks.html'.to_sym
      end

      get '/checks/:id' do
        check_id  = params[:id]

        @current_time = Time.now

        # @check = Flapjack::Data::Check.find_by_id(check_id)
        # halt(404, "Could not find check '#{check_id}'") if @check.nil?

    #     last_change = @check.states.last
    #     last_update = @check.latest_notifications.last

    #     @check_last_change      = last_change ? last_change.timestamp : nil

    #     @check_state            = last_update ? last_update.condition : nil
    #     @check_last_update      = last_update ? last_update.timestamp : nil
    #     @check_summary          = last_update ? last_update.summary   : nil
    #     @check_details          = last_update ? last_update.details   : nil
    #     @check_perfdata         = last_update ? last_update.perfdata  : nil

    #     @last_notifications = @check.latest_notifications.all.each_with_object({}) do |entry, memo|
    #       t = Time.at(entry.timestamp)
    #       memo[(entry.action || entry.condition).to_sym] = {
    #         :time => t.to_s,
    #         :relative => relative_time_ago(@current_time, t) + " ago",
    #         :summary => entry.summary
    #       }
    #     end

    #     # # don't think this is needed any more
    #     # @last_notifications[:acknowledgement] =
    #     #   @check.states.intersect(:action => 'acknowledgement',
    #     #                           :notified => true).last

    #     @scheduled_maintenances = @check.scheduled_maintenances_by_start.all
    #     @acknowledgement_id = if Flapjack::Data::Condition.healthy?(@check_state)
    #       nil
    #     else
    #       @check.ack_hash
    #     end

    #     @current_scheduled_maintenance   = @check.scheduled_maintenance_at(@current_time)
    #     @current_unscheduled_maintenance = @check.unscheduled_maintenance_at(@current_time)

    #     Flapjack::Data::Contact.lock(Flapjack::Data::Medium,
    #       Flapjack::Data::Rule, Flapjack::Data::Route) do

    #       rule_ids_by_contact_id, route_ids_by_rule_id =
    #         @check.rule_ids_and_route_ids

    #       if rule_ids_by_contact_id.empty?
    #         @contacts = []
    #         @media_by_contact_id = {}
    #       else
    #         @contacts = Flapjack::Data::Contact.
    #           intersect(:id => rule_ids_by_contact_id.keys).sort(:name).all

    #         rule_ids = Set.new(rule_ids_by_contact_id.values.flatten)

    #         if rule_ids.empty?
    #           @media_by_contact_id = {}
    #         else

    #           media_ids_by_rule_id = Flapjack::Data::Rule.
    #             intersect(:id => rule_ids).associated_ids_for(:media)

    #           media_ids = Set.new(media_ids_by_rule_id.values.flatten)

    #           if media_ids.empty?
    #             @media_by_contact_id = {}
    #           else
    #             media_ids_by_contact_id = Flapjack::Data::Medium.
    #               intersect(:id => media_ids).associated_ids_for(:contact)

    #             @media_by_contact_id = @contacts.each_with_object({}) do |contact, memo|
    #               m_ids = media_ids_by_contact_id[contact.id]
    #               next if m_ids.nil? || m_ids.empty?
    #               memo[contact.id] = Flapjack::Data::Medium.intersect(:id => m_ids).all
    #             end
    #           end
    #         end
    #       end
        # end

    #     @state_changes = @check.states.intersect_range(nil, @current_time.to_i,
    #                        :desc => true, :limit => 20, :by_score => true).all

        erb 'check.html'.to_sym
      end

    #   post "/unscheduled_maintenances/checks/:id" do
    #     check_id           = params[:id]
    #     summary            = params[:summary]
    #     acknowledgement_id = params[:acknowledgement_id]

    #     dur = ChronicDuration.parse(params[:duration] || '')
    #     duration = (dur.nil? || (dur <= 0)) ? (4 * 60 * 60) : dur

    #     check = Flapjack::Data::Check.find_by_id(check_id)
    #     halt(404, "Could not find check '#{check_id}'") if check.nil?

    #     ack = Flapjack::Data::Event.create_acknowledgements(
    #       config['processor_queue'] || 'events',
    #       [check],
    #       :summary => (summary || ''),
    #       :acknowledgement_id => acknowledgement_id,
    #       :duration => duration,
    #     )

    #     redirect back
    #   end

    #   patch '/unscheduled_maintenances/checks/:id' do
    #     check_id  = params[:id]

    #     check = Flapjack::Data::Check.find_by_id(check_id)
    #     halt(404, "Could not find check '#{check_id}'") if check.nil?

    #     check.clear_unscheduled_maintenance(Time.now.to_i)

    #     redirect back
    #   end

    #   # create scheduled maintenance
    #   post '/scheduled_maintenances/checks/:id' do
    #     check_id  = params[:id]

    #     start_time = Chronic.parse(params[:start_time]).to_i
    #     raise ArgumentError, "start time parsed to zero" unless start_time > 0
    #     duration   = ChronicDuration.parse(params[:duration])
    #     summary    = params[:summary]

    #     check = Flapjack::Data::Check.find_by_id(check_id)
    #     halt(404, "Could not find check '#{check_id}'") if check.nil?

    #     sched_maint = Flapjack::Data::ScheduledMaintenance.new(:start_time => start_time,
    #       :end_time => start_time + duration, :summary => summary)
    #     sched_maint.save
    #     check.scheduled_maintenances << sched_maint

    #     redirect back
    #   end

    #   # delete a scheduled maintenance
    #   delete '/scheduled_maintenances/checks/:id' do
    #     check_id  = params[:id]

    #     # TODO better error checking on this param?
    #     start_time = Time.parse(params[:start_time])

    #     check = Flapjack::Data::Check.find_by_id(check_id)
    #     halt(404, "Could not find check '#{check_id}'") if check.nil?

    #     # TODO maybe intersect_range should auto-coerce for timestamp fields?
    #     # (actually, this should just pass sched maint ID in now that it can)
    #     sched_maints = check.scheduled_maintenances_by_start.
    #       intersect_range(start_time.to_i, start_time.to_i, :by_score => true).all
    #     halt(404, "No scheduled maintenance periods found") if sched_maints.empty?

    #     sched_maints.each do |sched_maint|
    #       check.end_scheduled_maintenance(sched_maint, Time.now)
    #     end

    #     redirect back
    #   end

      get '/contacts' do
        opts = {}
        @name = params[:name]
        opts.update(:name => @name) unless @name.nil?

        @contacts = Flapjack::Diner.contacts(:page => params[:page],
          :filter => opts, :sort => '+name')

        unless @contacts.nil?
          @pagination = pagination_from_context(Flapjack::Diner.context)
          unless @pagination.nil?
            @links = create_pagination_links(@pagination[:page],
              @pagination[:total_pages])
          end
        end

        erb 'contacts.html'.to_sym
      end

      get "/contacts/:id" do
        contact_id = params[:id]

        @contact = Flapjack::Diner.contacts(contact_id, :include => 'media')
        halt(404, "Could not find contact '#{contact_id}'") if @contact.nil?

        context = Flapjack::Diner.context
        @media = context[:included] unless context.nil?

        # check_refs = Flapjack::Diner.contacts_link_checks(contact_id)
        # unless check_refs.nil?
          # check_ids  =
        # end

        @checks = []

        erb 'contact.html'.to_sym
      end

      error do
        e = env['sinatra.error']
        # trace = e.backtrace.join("\n")
        # puts trace

        # Rack::CommonLogger doesn't log requests which result in exceptions.
        # If you want something done properly, do it yourself...
        access_log = self.class.instance_variable_get('@middleware').detect {|mw|
          mw.first.is_a?(::Rack::CommonLogger)
        }
        unless access_log.nil?
          access_log.first.send(:log, status_code,
            ::Rack::Utils::HeaderHash.new(headers), msg,
            env['request_timestamp'])
        end
        self.class.instance_variable_get('@show_exceptions').pretty(env, e)
      end


    private

    #   def check_state(check, time)
    #     latest_notif = check.latest_notifications.last

    #     lc = check.states.last
    #     last_change   = lc.nil? ? 'never' :
    #       (ChronicDuration.output(time.to_i - lc.timestamp.to_i,
    #                               :format => :short, :keep_zero => true,
    #                               :units => 2) || '0s')

    #     lu = lc.nil? ? nil : lc.entries.last
    #     last_update   = lu.nil? ? 'never' :
    #       (ChronicDuration.output(time.to_i - lu.timestamp.to_i,
    #                               :format => :short, :keep_zero => true,
    #                               :units => 2) || '0s')

    #     summary = nil
    #     cond    = nil

    #     if latest_notif.nil?
    #       last_notified = 'never'
    #     else
    #       cond = latest_notif.condition

    #       summary = latest_notif.summary
    #       summary = summary[0..76] + '...' unless summary.nil? || (summary.length < 81)

    #       ln = latest_notif.timestamp

    #       last_notified = (ChronicDuration.output(time.to_i - ln.to_i,
    #                        :format => :short, :keep_zero => true, :units => 2) || '0s')
    #     end

    #     [(cond     || '-'),
    #      (summary  || '-'),
    #      last_change,
    #      last_update,
    #      check.in_unscheduled_maintenance?,
    #      check.in_scheduled_maintenance?,
    #      last_notified
    #     ]
    #   end

      def pagination_from_context(context)
        ((context || {})[:meta] || {})[:pagination]
      end

      def require_js(*js)
        @required_js ||= []
        @required_js += js
        @required_js.uniq!
      end

      def require_css(*css)
        @required_css ||= []
        @required_css += css
        @required_css.uniq!
      end

      def include_required_js
        return "" if @required_js.nil?
        @required_js.map { |filename|
          "<script type='text/javascript' src='#{link_to("js/#{filename}.js")}'></script>"
        }.join("\n    ")
      end

      def include_required_css
        return "" if @required_css.nil?
        @required_css.map { |filename|
          %(<link rel="stylesheet" href="#{link_to("css/#{filename}.css")}" media="screen">)
        }.join("\n    ")
      end

      # from http://gist.github.com/98310
      def link_to(url_fragment, mode=:path_only)
        case mode
        when :path_only
          base = @base_url
        when :full_url
          if (request.scheme == 'http' && request.port == 80 ||
              request.scheme == 'https' && request.port == 443)
            port = ""
          else
            port = ":#{request.port}"
          end
          base = "#{request.scheme}://#{request.host}#{port}#{request.script_name}"
        else
          raise "Unknown script_url mode #{mode}"
        end
        "#{base}#{url_fragment}"
      end

      def page_title(string)
        @page_title = string
      end

      def include_page_title
        @page_title ? "#{@page_title} | Flapjack" : "Flapjack"
      end

      def boolean_from_str(str)
        case str
        when '0', 'f', 'false', 'n', 'no'
          false
        when '1', 't', 'true', 'y', 'yes'
          true
        end
      end

      def create_pagination_links(page, total_pages)
        pages = {}
        pages[:first] = 1
        pages[:prev]  = page - 1 if (page > 1)
        pages[:next]  = page + 1 if page < total_pages
        pages[:last]  = total_pages

        url_without_params = request.url.split('?').first

        links = {}
        pages.each do |key, value|
          page_params = {'page' => value }
          new_params = request.params.merge(page_params)
          links[key] = "#{url_without_params}?#{new_params.to_query}"
        end
        links
      end

    end

  end

end