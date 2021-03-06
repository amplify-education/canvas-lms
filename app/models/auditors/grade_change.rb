#
# Copyright (C) 2013 - present Instructure, Inc.
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
#

class Auditors::GradeChange
  class Record < Auditors::Record
    attributes :account_id,
               :grade_after,
               :grade_before,
               :submission_id,
               :version_number,
               :student_id,
               :assignment_id,
               :context_id,
               :context_type,
               :grader_id,
               :graded_anonymously,
               :excused_after,
               :excused_before,
               :score_after,
               :score_before,
               :points_possible_after,
               :points_possible_before
    attr_accessor :grade_current

    def self.generate(submission, event_type=nil)
      new(
        'submission' => submission,
        'event_type' => event_type
      )
    end

    def initialize(*args)
      super(*args)

      if attributes['submission']
        self.submission = attributes.delete('submission')
      end
    end

    def version
      @submission.version.get(version_number)
    end

    def submission
      @submission ||= Submission.active.find(submission_id)
    end

    def previous_submission
      @previous_submission ||= submission.versions.previous.try(:model)
    end

    # Returns assignment referenced by the previous version of the submission.
    # We use the assignment_changed_not_sub flag to be sure the assignment has
    # been versioned along with the submission.
    def previous_assignment
      @previous_assignment ||= begin
        if submission.assignment_changed_not_sub
          model = submission.assignment.versions.previous.try(:model)
        end
        model || assignment
      end
    end

    def submission=(submission)
      @submission = submission

      attributes['submission_id'] = Shard.global_id_for(@submission)
      attributes['version_number'] = @submission.version_number
      attributes['grade_after'] = @submission.grade
      attributes['grade_before'] = previous_submission.try(:grade)
      attributes['assignment_id'] = Shard.global_id_for(assignment)
      attributes['grader_id'] = grader ? Shard.global_id_for(grader) : nil
      attributes['graded_anonymously'] = @submission.graded_anonymously
      attributes['student_id'] = Shard.global_id_for(student)
      attributes['context_id'] = Shard.global_id_for(context)
      attributes['context_type'] = assignment.context_type
      attributes['account_id'] = Shard.global_id_for(context.account)
      attributes['excused_after'] = @submission.excused?
      attributes['excused_before'] = !!previous_submission.try(:excused?)
      attributes['score_after'] = @submission.score
      attributes['score_before'] = previous_submission.try(:score)
      attributes['points_possible_after'] = assignment.points_possible
      attributes['points_possible_before'] = previous_assignment.points_possible
    end

    def root_account
      account.root_account
    end

    def account
      context.account
    end

    def assignment
      submission.assignment
    end

    def course
      context if context_type == 'Course'
    end

    def course_id
      context_id if context_type == 'Course'
    end

    def context
      assignment.context
    end

    def grader
      if submission.grader_id && !submission.autograded?
        @grader ||= User.find(submission.grader_id)
      end
    end

    def student
      submission.user
    end

    def submission_version
      return @submission_version if @submission_version.present?

      submission.shard.activate do
        @submission_version = SubmissionVersion.where(
          context_type: context_type,
          context_id: context_id,
          version_id: version_id
        ).first
      end

      @submission_version
    end
  end

  # rubocop:disable Metrics/BlockLength
  Stream = Auditors.stream do
    backend_strategy :cassandra
    active_record_type Auditors::ActiveRecord::GradeChangeRecord
    database -> { Canvas::Cassandra::DatabaseBuilder.from_config(:auditors) }
    table :grade_changes
    record_type Auditors::GradeChange::Record
    read_consistency_level -> { Canvas::Cassandra::DatabaseBuilder.read_consistency_setting(:auditors) }

    add_index :assignment do
      table :grade_changes_by_assignment
      entry_proc lambda{ |record| record.assignment }
      key_proc lambda{ |assignment| assignment.global_id }
    end

    add_index :course do
      table :grade_changes_by_course
      entry_proc lambda{ |record| record.course }
      key_proc lambda{ |course| course.global_id }
    end

    add_index :root_account_grader do
      table :grade_changes_by_root_account_grader
      # We don't want to index events for nil graders and currently we are not
      # indexing events for auto grader in cassandra.
      entry_proc lambda{ |record| [record.root_account, record.grader] if record.grader && !record.submission.autograded? }
      key_proc lambda{ |root_account, grader| [root_account.global_id, grader.global_id] }
    end

    add_index :root_account_student do
      table :grade_changes_by_root_account_student
      entry_proc lambda{ |record| [record.root_account, record.student] }
      key_proc lambda{ |root_account, student| [root_account.global_id, student.global_id] }
    end

    add_index :course_assignment do
      table :grade_changes_by_course_assignment
      entry_proc lambda { |record| [record.course, record.assignment] }
      key_proc lambda { |course, assignment| [course.global_id, assignment.global_id] }
    end

    add_index :course_assignment_grader do
      table :grade_changes_by_course_assignment_grader
      entry_proc lambda { |record|
        [record.course, record.assignment, record.grader] if record.grader && !record.submission.autograded?
      }
      key_proc lambda { |course, assignment, grader| [course.global_id, assignment.global_id, grader.global_id] }
    end

    add_index :course_assignment_grader_student do
      table :grade_change_by_course_assignment_grader_student
      entry_proc lambda { |record|
        if record.grader && !record.submission.autograded?
          [record.course, record.assignment, record.grader, record.student]
        end
      }
      key_proc lambda { |course, assignment, grader, student|
        [course.global_id, assignment.global_id, grader.global_id, student.global_id]
      }
    end

    add_index :course_assignment_student do
      table :grade_changes_by_course_assignment_student
      entry_proc lambda { |record| [record.course, record.assignment, record.student] }
      key_proc lambda { |course, assignment, student| [course.global_id, assignment.global_id, student.global_id] }
    end

    add_index :course_grader do
      table :grade_changes_by_course_grader
      entry_proc lambda { |record| [record.course, record.grader] if record.grader && !record.submission.autograded? }
      key_proc lambda { |course, grader| [course.global_id, grader.global_id] }
    end

    add_index :course_grader_student do
      table :grade_changes_by_course_grader_student
      entry_proc lambda { |record|
        [record.course, record.grader, record.student] if record.grader && !record.submission.autograded?
      }
      key_proc lambda { |course, grader, student| [course.global_id, grader.global_id, student.global_id] }
    end

    add_index :course_student do
      table :grade_changes_by_course_student
      entry_proc lambda { |record| [record.course, record.student] }
      key_proc lambda { |course, student| [course.global_id, student.global_id] }
    end

  end
  # rubocop:enable Metrics/BlockLength

  def self.record(skip_insert: false, submission:, event_type: nil)
    return unless submission
    event_record = nil
    submission.shard.activate do
      event_record = Auditors::GradeChange::Record.generate(submission, event_type)
      Canvas::LiveEvents.grade_changed(submission, event_record.previous_submission, event_record.previous_assignment)
      unless skip_insert
        Auditors::GradeChange::Stream.insert(event_record, {backend_strategy: :cassandra}) if Auditors.write_to_cassandra?
        Auditors::GradeChange::Stream.insert(event_record, {backend_strategy: :active_record}) if Auditors.write_to_postgres?
      end
    end
    event_record
  end

  def self.for_root_account_student(account, student, options={})
    account.shard.activate do
      Auditors::GradeChange::Stream.for_root_account_student(account, student, options)
    end
  end

  def self.for_course(course, options={})
    course.shard.activate do
      Auditors::GradeChange::Stream.for_course(course, options)
    end
  end

  def self.for_root_account_grader(account, grader, options={})
    account.shard.activate do
      Auditors::GradeChange::Stream.for_root_account_grader(account, grader, options)
    end
  end

  def self.for_assignment(assignment, options={})
    assignment.shard.activate do
      Auditors::GradeChange::Stream.for_assignment(assignment, options)
    end
  end

  # These are the groupings this method expects to receive:
  # course assignment
  # course assignment grader
  # course assignment grader student
  # course assignment student
  # course grader
  # course grader student
  # course student
  def self.for_course_and_other_arguments(course, arguments, options={})
    course.shard.activate do
      if arguments[:assignment] && arguments[:grader] && arguments[:student]
        Auditors::GradeChange::Stream.for_course_assignment_grader_student(course,
          arguments[:assignment], arguments[:grader], arguments[:student], options)

      elsif arguments[:assignment] && arguments[:grader]
        Auditors::GradeChange::Stream.for_course_assignment_grader(course, arguments[:assignment],
          arguments[:grader], options)

      elsif arguments[:assignment] && arguments[:student]
        Auditors::GradeChange::Stream.for_course_assignment_student(course, arguments[:assignment],
          arguments[:student], options)

      elsif arguments[:assignment]
        Auditors::GradeChange::Stream.for_course_assignment(course, arguments[:assignment], options)

      elsif arguments[:grader] && arguments[:student]
        Auditors::GradeChange::Stream.for_course_grader_student(course, arguments[:grader], arguments[:student],
          options)

      elsif arguments[:grader]
        Auditors::GradeChange::Stream.for_course_grader(course, arguments[:grader], options)

      elsif arguments[:student]
        Auditors::GradeChange::Stream.for_course_student(course, arguments[:student], options)
      end
    end
  end
end
