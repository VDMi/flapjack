#!/usr/bin/env ruby

require 'active_support/time'

require 'flapjack/exceptions'
require 'flapjack/redis_proxy'
require 'flapjack/record_queue'
require 'flapjack/utility'

require 'flapjack/data/alert'
require 'flapjack/data/check'
require 'flapjack/data/contact'
require 'flapjack/data/event'
require 'flapjack/data/notification'

module Flapjack

  class Notifier

    include Flapjack::Utility

    def initialize(opts = {})
      @lock = opts[:lock]
      @config = opts[:config] || {}

      @queue = Flapjack::RecordQueue.new(@config['queue'] || 'notifications',
                 Flapjack::Data::Notification)

      queue_configs = @config.find_all {|k, v| k =~ /_queue$/ }
      @queues = Hash[queue_configs.map {|k, v|
        [k[/^(.*)_queue$/, 1], Flapjack::RecordQueue.new(v, Flapjack::Data::Alert)]
      }]

      raise "No queues for media transports" if @queues.empty?

      tz_string = @config['default_contact_timezone'] || ENV['TZ'] || 'UTC'
      tz = ActiveSupport::TimeZone[tz_string.untaint]
      if tz.nil?
        raise "Invalid timezone string specified in default_contact_timezone or TZ (#{tz_string})"
      end
      @default_contact_timezone = tz
    end

    def start
      begin
        Zermelo.redis = Flapjack.redis

        loop do
          @lock.synchronize do
            @queue.foreach {|notif| process_notification(notif) }
          end

          @queue.wait
        end
      ensure
        Flapjack.redis.quit
      end
    end

    def stop_type
      :exception
    end

  private

    # takes an event for which messages should be generated, works out the type of
    # notification, updates the notification history in redis, generates the
    # notifications
    def process_notification(notification)
      Flapjack.logger.debug { "Processing notification: #{notification.inspect}" }

      check       = notification.check
      check_name  = check.name

      # TODO check whether time should come from something stored in the notification
      alerts = alerts_for(notification, check,
        :transports => @queues.keys, :time => Time.now)

      if alerts.nil? || alerts.empty?
        Flapjack.logger.info { "No alerts" }
      else
        Flapjack.logger.info { "Alerts: #{alerts.size}" }

        alerts.each do |alert|
          medium = alert.medium

          Flapjack.logger.info {
            "#{check_name} | #{medium.contact.id} | " \
            "#{medium.transport} | #{medium.address}\n" \
            "Enqueueing #{medium.transport} alert for " \
            "#{check_name} to #{medium.address} " \
            " rollup: #{alert.rollup || '-'}"
          }

          @queues[medium.transport].push(alert)
        end
      end

      notification.destroy
    end

    def alerts_for(notification, check, opts = {})
      time = opts[:time]

      in_sched   = check.in_scheduled_maintenance?(time)
      in_unsched = check.in_unscheduled_maintenance?(time)

      rule_ids_by_contact_id, route_ids =
        check.rule_ids_and_route_ids(:severity => notification.severity)

      notification_state = notification.state

      if rule_ids_by_contact_id.empty?
        alert_type = Flapjack::Data::Alert.notification_type(notification_state.action,
          notification_state.condition)

        Flapjack.logger.info { "#{check.name} | #{alert_type} | NO RULES" }
        return
      end

      transports = opts[:transports]

      Flapjack.logger.debug { "contact_ids: #{rule_ids_by_contact_id.keys.size}" }

      contacts = rule_ids_by_contact_id.empty? ? [] :
        Flapjack::Data::Contact.find_by_ids(*rule_ids_by_contact_id.keys)
      return if contacts.empty?

      # TODO pass in base time from outside (cast to zone per contact), so
      # all alerts from this notification use a consistent time

      rule_ids = contacts.inject([]) do |memo, contact|
        rules = Flapjack::Data::Rule.find_by_ids(*rule_ids_by_contact_id[contact.id])
        next memo if rules.empty?

        timezone = contact.time_zone || @default_contact_timezone
        rules.select! {|rule| rule.is_occurring_at?(time, timezone) }

        memo += rules.map(&:id)
        memo
      end

      Flapjack.logger.debug "rule_ids after time: #{rule_ids.size}"
      return if rule_ids.empty?

      Flapjack::Data::Medium.lock(Flapjack::Data::Check,
                                  Flapjack::Data::ScheduledMaintenance,
                                  Flapjack::Data::UnscheduledMaintenance,
                                  Flapjack::Data::Rule,
                                  Flapjack::Data::Alert,
                                  Flapjack::Data::Route,
                                  Flapjack::Data::Notification,
                                  Flapjack::Data::Contact,
                                  Flapjack::Data::State) do

        blackhole_media_ids = Flapjack::Data::Rule.
          intersect(:id => rule_ids, :is_blackhole => true).
          associated_ids_for(:media).values.reduce(Set.new, :|)

        Flapjack.logger.debug "blackhole_media_ids: #{blackhole_media_ids.inspect}"

        media_ids = Flapjack::Data::Rule.
          intersect(:id => rule_ids, :is_blackhole => [nil, false]).
          associated_ids_for(:media).values.reduce(Set.new, :|)

        Flapjack.logger.debug "media ids pre-blackhole: #{media_ids.inspect}"

        media_ids -= blackhole_media_ids

        Flapjack.logger.debug "media ids post-blackhole: #{media_ids.inspect}"

        alertable_media = Flapjack::Data::Medium.intersect(:id => media_ids,
          :transport => transports).all

        # we want to consider this as 'alerting' for the purpose of rollup
        # calculations, if it's failing, even if we won't notify on this media

        Flapjack.logger.debug "healthy #{Flapjack::Data::Condition.healthy?(notification_state.condition)}"
        Flapjack.logger.debug "sched #{in_sched}"
        Flapjack.logger.debug "unsched #{in_unsched}"

        this_notification_failure = !(Flapjack::Data::Condition.healthy?(notification_state.condition) ||
          in_sched || in_unsched)

        this_notification_ok = 'acknowledgement'.eql?(notification_state.action) ||
          Flapjack::Data::Condition.healthy?(notification_state.condition)
        is_a_test            = 'test_notifications'.eql?(notification_state.action)

        unless is_a_test
          Flapjack::Data::Route.intersect(:id => route_ids).each do |route|
            route.is_alerting = this_notification_failure
            route.save # no-op if the value didn't change
          end
        end

        Flapjack.logger.debug "pre-media test: \n" \
          "  this_notification_failure = #{this_notification_failure}\n" \
          "  this_notification_ok      = #{this_notification_ok}\n" \
          "  is_a_test                 = #{is_a_test}"

        alertable_media.each_with_object([]) do |medium, memo|

          Flapjack.logger.debug "media test: #{medium.transport}, #{medium.id}"

          if this_notification_failure
            medium.alerting_checks << check
          elsif this_notification_ok
            medium.alerting_checks.remove(check)
          end

          alerting_check_ids = medium.alerting_checks.intersect(:enabled => true).ids

          Flapjack.logger.debug {
            " alerting_checks: #{alerting_check_ids.inspect}"
          }

          last_state = medium.last_state

          last_state_ok = last_state.nil? ? nil :
            (Flapjack::Data::Condition.healthy?(last_state.condition) ||
            'acknowledgement'.eql?(last_state.action))

          alert_rollup = if !medium.rollup_threshold.nil? &&
            (alerting_check_ids.size >= medium.rollup_threshold)

            'problem'
          elsif 'problem'.eql?(medium.last_rollup_type)
            'recovery'
          else
            nil
          end

          Flapjack.logger.debug "last_state #{last_state.inspect}"

          interval_allows = last_state.nil? ||
            ((!last_state_ok && this_notification_failure) &&
             ((last_state.created_at + (medium.interval || 0)) < notification_state.created_at))

          Flapjack.logger.debug "  last_state_ok = #{last_state_ok}\n" \
            "  interval_allows  = #{interval_allows}\n" \
            "  alert_rollup , last_rollup_type = #{alert_rollup} , #{medium.last_rollup_type}\n" \
            "  condition , last_notification_condition  = #{notification_state.condition} , #{last_state.nil? ? '-' : last_state.condition}\n" \
            "  no_previous_notification  = #{last_state.nil?}\n"

          next unless is_a_test || last_state.nil? ||
              (!last_state_ok && this_notification_ok) ||
            (alert_rollup != medium.last_rollup_type) ||
            ('acknowledgement'.eql?(last_state.action) && this_notification_failure) ||
            (notification_state.condition != last_state.condition) ||
            interval_allows

          alert = Flapjack::Data::Alert.new(:condition => notification_state.condition,
            :action => notification_state.action,
            :last_condition => (last_state.nil? ? nil : last_state.condition),
            :last_action => (last_state.nil? ? nil : last_state.action),
            :condition_duration => notification.condition_duration,
            :acknowledgement_duration => notification.duration,
            :rollup => alert_rollup)

          unless alert_rollup.nil? || alerting_check_ids.empty?
            alert.rollup_states = Flapjack::Data::Check.intersect(:id => alerting_check_ids).all.each_with_object({}) do |check, memo|
              cond = check.condition
              memo[cond] ||= []
              memo[cond] << check.name
            end
          end

          unless alert.save
            raise "Couldn't save alert: #{alert.errors.full_messages.inspect}"
          end

          medium.alerts << alert
          check.alerts  << alert

          Flapjack.logger.info "alerting for #{medium.transport}, #{medium.address}"

          unless 'test_notifications'.eql?(notification_state.action)
            notification_state.latest_media << medium
            medium.last_rollup_type = alert.rollup
            medium.save
          end

          memo << alert
        end
      end
    end

  end
end
