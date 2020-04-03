#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.

class AccountNotification < ActiveRecord::Base
  validates_presence_of :start_at, :end_at, :subject, :message, :account_id
  validate :validate_dates
  validate :send_message_not_set_for_site_admin
  belongs_to :account, :touch => true
  belongs_to :user
  has_many :account_notification_roles, dependent: :destroy
  validates_length_of :message, :maximum => maximum_text_length, :allow_nil => false, :allow_blank => false
  validates_length_of :subject, :maximum => maximum_string_length
  sanitize_field :message, CanvasSanitize::SANITIZE

  after_save :create_alert
  after_save :queue_message_broadcast

  ACCOUNT_SERVICE_NOTIFICATION_FLAGS = %w[account_survey_notifications]
  validates_inclusion_of :required_account_service, in: ACCOUNT_SERVICE_NOTIFICATION_FLAGS, allow_nil: true

  validates_inclusion_of :months_in_display_cycle, in: 1..48, allow_nil: true

  def validate_dates
    if self.start_at && self.end_at
      errors.add(:end_at, t('errors.invalid_account_notification_end_at', "Account notification end time precedes start time")) if self.end_at < self.start_at
    end
  end

  def create_alert
    if self.start_at > Time.zone.now
      self.send_later_enqueue_args(:create_alert, {
        :run_at => self.start_at,
        :on_conflict => :overwrite,
        :singleton => "create_notification_alert:#{self.global_id}"
      })
      return
    end

    return unless self.account.root_account?

    roles = self.account_notification_roles.map(&:role_name)
    return if roles.count > 0 && (roles & ['StudentEnrollment', 'ObserverEnrollment']).none?

    thresholds = ObserverAlertThreshold.active.where(observer: User.of_account(self.account), alert_type: 'institution_announcement')
    thresholds.each do |threshold|
      ObserverAlert.create(student: threshold.student, observer: threshold.observer,
                           observer_alert_threshold: threshold, context: self,
                           alert_type: 'institution_announcement', action_date: self.start_at,
                           title: I18n.t('Institution announcement: "%{announcement_title}"', {
                             announcement_title: self.subject
                           }))
    end
  end

  def self.for_user_and_account(user, root_account)
    if root_account.site_admin?
      current = self.for_account(root_account)
    else
      course_ids = user.enrollments.active_or_pending.shard(user.in_region_associated_shards).distinct.pluck(:course_id) # fetch sharded course ids
      # and then fetch account_ids separately - using pluck on a joined column doesn't give relative ids
      all_account_ids = Course.where(:id => course_ids).not_deleted.
        distinct.pluck(:account_id, :root_account_id).flatten.uniq
      all_account_ids += user.account_users.active.shard(user.in_region_associated_shards).
        joins(:account).where(accounts: {workflow_state: 'active'}).
        distinct.pluck(:account_id).uniq
      all_account_ids = Account.multi_account_chain_ids(all_account_ids) # get all parent sub-accounts too
      current = self.for_account(root_account, all_account_ids)
    end

    user_role_ids = {}
    sub_account_ids_map = {}

    current.select! do |announcement|
      # use role.id instead of role_id to trigger Role#id magic for built in
      # roles. try(:id) because the AccountNotificationRole may have an
      # explicitly nil role_id to indicate the announcement's intended for
      # users not enrolled in any courses
      role_ids = announcement.account_notification_roles.map { |anr| anr.role&.role_for_shard&.id }

      unless role_ids.empty? || user_role_ids.key?(announcement.account_id)
        # choose enrollments and account users to inspect
        if announcement.account.site_admin?
          enrollments = user.enrollments.shard(user.in_region_associated_shards).active_or_pending.distinct.select(:role_id).to_a
          account_users = user.account_users.shard(user.in_region_associated_shards).distinct.select(:role_id).to_a
        else
          announcement.shard.activate do
            sub_account_ids_map[announcement.account_id] ||=
              Account.sub_account_ids_recursive(announcement.account_id) + [announcement.account_id]
            enrollments = Enrollment.where(user_id: user).active_or_pending.joins(:course).
              where(:courses => {:account_id => sub_account_ids_map[announcement.account_id]}).select(:role_id).to_a
            account_users = announcement.account.root_account.cached_all_account_users_for(user)
          end
        end

        # preload role objects for those enrollments and account users
        ActiveRecord::Associations::Preloader.new.preload(enrollments, [:role])
        ActiveRecord::Associations::Preloader.new.preload(account_users, [:role])

        # map to role ids. user role.id instead of role_id to trigger Role#id
        # magic for built in roles. announcements intended for users not
        # enrolled in any courses have the NilEnrollment role type
        user_role_ids[announcement.account_id] = enrollments.map{ |e| e.role.role_for_shard.id }
        user_role_ids[announcement.account_id] = [nil] if user_role_ids[announcement.account_id].empty?
        user_role_ids[announcement.account_id] |= account_users.map{ |au| au.role.role_for_shard.id }
      end

      role_ids.empty? || (role_ids & user_role_ids[announcement.account_id]).present?
    end

    user.shard.activate do
      closed_ids = user.get_preference(:closed_notifications) || []
      # If there are ids marked as 'closed' that are no longer
      # applicable, they probably need to be cleared out.
      current_ids = current.map(&:id)
      if !(closed_ids - current_ids).empty?
        user.set_preference(:closed_notifications, closed_ids & current_ids)
      end
      current.reject! { |announcement| closed_ids.include?(announcement.id) }

      # filter out announcements that have a periodic cycle of display,
      # and the user isn't in the set of users to display it to this month (based
      # on user id)
      current.reject! do |announcement|
        if months_in_period = announcement.months_in_display_cycle
          !self.display_for_user?(user.id, months_in_period)
        end
      end

      roles = user.enrollments.shard(user.in_region_associated_shards).active_or_pending.distinct.pluck(:type)

      if roles == ['StudentEnrollment'] && !root_account.include_students_in_global_survey?
        current.reject! { |announcement| announcement.required_account_service == 'account_survey_notifications' }
      end
    end

    current
  end

  def self.for_account(root_account, all_visible_account_ids=nil)
    # Refreshes every 10 minutes at the longest
    all_account_ids_hash = Digest::MD5.hexdigest all_visible_account_ids.try(:sort).to_s
    Rails.cache.fetch(['account_notifications4', root_account, all_account_ids_hash].cache_key, expires_in: 10.minutes) do
      now = Time.now.utc
      # we always check the given account for the flag, even if the announcement is from the site_admin account
      # this allows us to make a global announcement that is filtered to only accounts with this flag
      enabled_flags = ACCOUNT_SERVICE_NOTIFICATION_FLAGS & root_account.allowed_services_hash.keys.map(&:to_s)
      account_ids = root_account.account_chain(include_site_admin: true).map(&:id)
      if all_visible_account_ids
        account_ids += all_visible_account_ids
        account_ids.uniq!
      end

      Shard.partition_by_shard(account_ids) do |sharded_account_ids|
        scope = AccountNotification.where("account_id IN (?) AND start_at <? AND end_at>?", sharded_account_ids, now, now).
          where("required_account_service IS NULL OR required_account_service IN (?)", enabled_flags).
          order('start_at DESC').
          preload({:account => :root_account}, account_notification_roles: :role)
        if Shard.current == root_account.shard
          # get the sub-account ids that are directly from the current root account
          domain_account_ids = Account.where(:id => sharded_account_ids, :root_account_id => root_account.id).pluck(:id) + [root_account.id]
          scope = scope.where("domain_specific = ? OR account_id IN (?)", false, domain_account_ids)
        else
          scope = scope.where(:domain_specific => false)
        end
        scope.to_a
      end
    end
  end

  def self.default_months_in_display_cycle
    Setting.get("account_notification_default_months_in_display_cycle", "9").to_i
  end

  # private
  def self.display_for_user?(user_id, months_in_period, current_time = Time.now.utc)
    # we just need a stable reference point, doesn't matter what it is, so
    # let's use unix epoch
    start_time = Time.at(0).utc
    months_since_start_time = (current_time.year - start_time.year) * 12 + (current_time.month - start_time.month)
    periods_since_start_time = months_since_start_time / months_in_period
    months_into_current_period = months_since_start_time % months_in_period
    mod_value = (Random.new(periods_since_start_time).rand(months_in_period) + months_into_current_period) % months_in_period
    user_id % months_in_period == mod_value
  end

  attr_accessor :message_recipients
  has_a_broadcast_policy

  set_broadcast_policy do |p|
    p.dispatch :account_notification
    p.to { self.message_recipients }
    p.whenever { |record|
      record.should_send_message? && record.message_recipients.present?
    }
  end

  def send_message_not_set_for_site_admin
    if self.send_message? && self.account.site_admin?
      # i mean maybe we could try but there are almost certainly better ways to send mass emails than this
      errors.add(:send_message, 'Cannot send messages for site admin accounts')
    end
  end

  def should_send_message?
    self.send_message? && !self.messages_sent_at &&
      (self.start_at.nil? || (self.start_at < Time.now.utc)) &&
      (self.end_at.nil? || (self.end_at > Time.now.utc))
  end

  def queue_message_broadcast
    if self.send_message? && !self.messages_sent_at && !self.message_recipients
      self.send_later_enqueue_args(:broadcast_messages, {
        :run_at => self.start_at || Time.now.utc,
        :on_conflict => :overwrite,
        :singleton => "account_notification_broadcast_messages:#{self.global_id}",
        :max_attempts => 1})
    end
  end

  def self.users_per_message_batch
    Setting.get("account_notification_message_batch_size", "1000").to_i
  end

  def broadcast_messages
    return unless self.should_send_message? # sanity check before we start grabbing user ids

    # don't try to send a message to an entire account in one job
    self.applicable_user_ids.each_slice(self.class.users_per_message_batch) do |sliced_user_ids|
      begin
        self.message_recipients = sliced_user_ids.map{|id| "user_#{id}"}
        self.save # trigger the broadcast policy
      ensure
        self.message_recipients = nil
      end
    end
    self.update_attribute(:messages_sent_at, Time.now.utc)
  end

  def applicable_user_ids
    roles = self.account_notification_roles.preload(:role).to_a.map(&:role)
    Shackles.activate(:slave) do
      self.class.applicable_user_ids_for_account_and_roles(self.account, roles)
    end
  end

  def self.applicable_user_ids_for_account_and_roles(account, roles)
    account.shard.activate do
      all_account_ids = Account.sub_account_ids_recursive(account.id) + [account.id]
      user_ids = Set.new
      get_everybody = roles.empty?

      course_roles = roles.select{|role| role.course_role?}.map(&:role_for_shard)
      if get_everybody || course_roles.any?
        Course.find_ids_in_ranges do |min_id, max_id|
          course_ids = Course.active.where(:id => min_id..max_id, :account_id => all_account_ids).pluck(:id)
          next unless course_ids.any?
          course_ids.each_slice(50) do |sliced_course_ids|
            scope = Enrollment.active_or_pending.where(:course_id => sliced_course_ids)
            scope = scope.where(:role_id => course_roles) unless get_everybody
            user_ids += scope.distinct.pluck(:user_id)
          end
        end
      end

      account_roles = roles.select{|role| role.account_role?}.map(&:role_for_shard)
      if get_everybody || account_roles.any?
        AccountUser.find_ids_in_ranges do |min_id, max_id|
          scope = AccountUser.where(:id => min_id..max_id).active.where(:account_id => all_account_ids)
          scope = scope.where(:role_id => account_roles) unless get_everybody
          user_ids += scope.distinct.pluck(:user_id)
        end
      end
      user_ids.to_a.sort
    end
  end
end
