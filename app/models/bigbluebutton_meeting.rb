# coding: utf-8
class BigbluebuttonMeeting < ActiveRecord::Base
  include ActiveModel::ForbiddenAttributesProtection

  belongs_to :room, :class_name => 'BigbluebuttonRoom'

  has_one :recording,
          :class_name => 'BigbluebuttonRecording',
          :foreign_key => 'meeting_id',
          :dependent => :destroy

  has_many :attendees,
           :class_name => 'BigbluebuttonAttendee',
           :dependent => :destroy

  validates :room, :presence => true

  validates :meetingid, :presence => true, :length => { :minimum => 1, :maximum => 100 }

  validates :create_time, :presence => true
  validates :create_time, :uniqueness => { :scope => :room_id }

  # Whether the meeting was created by the `user` or not.
  def created_by?(user)
    unless user.nil?
      userid = user.send(BigbluebuttonRails.configuration.user_attr_id)
      self.creator_id == userid
    else
      false
    end
  end
end
