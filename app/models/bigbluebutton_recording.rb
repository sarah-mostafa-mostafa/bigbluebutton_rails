class BigbluebuttonRecording < ActiveRecord::Base
  include ActiveModel::ForbiddenAttributesProtection

  # NOTE: when adding new attributes to recordings, add them to `recording_changed?`

  belongs_to :server, class_name: 'BigbluebuttonServer'
  belongs_to :room, class_name: 'BigbluebuttonRoom'
  belongs_to :meeting, class_name: 'BigbluebuttonMeeting'

  validates :server, :presence => true

  validates :recordid,
            :presence => true,
            :uniqueness => true

  has_many :metadata,
           :class_name => 'BigbluebuttonMetadata',
           :as => :owner,
           :dependent => :destroy

  has_many :playback_formats,
           :class_name => 'BigbluebuttonPlaybackFormat',
           :foreign_key => 'recording_id',
           :dependent => :destroy

  scope :published, -> { where(:published => true) }

  serialize :recording_users, Array

  def to_param
    self.recordid
  end

  def get_token(user, ip)
    server = BigbluebuttonServer.default
    user.present? ? authName = user.username : authName = "anonymous"
    api_token = server.api.send_api_request(:getRecordingToken, { authUser: authName, authAddr: ip, meetingID: self.recordid })
    str_token = api_token[:token]
    str_token
  end

  # Passing it on the url
  #
  def token_url(user, ip, playback)
    auth_token = get_token(user, ip)
    if auth_token.present?
      uri = playback.url
      uri += URI.parse(uri).query.blank? ? "?" : "&"
      uri += "token=#{auth_token}"
      uri
    end
  end

  def default_playback_format
    playback_formats.joins(:playback_type)
      .where("bigbluebutton_playback_types.default = ?", true).first
  end

  # Remove this recording from the server
  def delete_from_server!
    if self.server.present?
      self.server.send_delete_recordings(self.recordid)
    else
      false
    end
  end

  # Returns the overall (i.e. for all recordings) average length of recordings in seconds
  # Uses the length of the default playback format
  def self.overall_average_length
    avg = BigbluebuttonPlaybackFormat.joins(:playback_type)
          .where("bigbluebutton_playback_types.default = ?", true).average(:length)
    avg.nil? ? 0 : (avg.truncate(2) * 60)
  end

  # Returns the overall (i.e. for all recordings) average size of recordings in bytes
  # Uses the length of the default playback format
  def self.overall_average_size
    avg = BigbluebuttonRecording.average(:size)
    avg.nil? ? 0 : avg
  end

  # Compares a recording from the db with data from a getRecordings call.
  # If anything changed in the recording, returns true.
  # We select only the attributes that are saved and turn it all into sorted arrays
  # to compare. If new attributes are stored in recordings, they should be added here.
  #
  # This was created to speed up the full sync of recordings.
  # In the worst case the comparison is wrong and we're updating them all (same as
  # not using this method at all, which is ok).
  def self.recording_changed?(recording, data)
    # the attributes that are considered in the comparison
    keys = [:end_time, :meetingid,  :metadata, :playback, :published, :recordid, :size, :start_time] # rawSize is not stored at the moment
    keys_formats = [:length, :type, :url] # :size, :processingTime are not stored at the moment

    # the data from getRecordings
    data_clone = data.deep_dup
    data_clone[:size] = data_clone[:size].to_s if data_clone.key?(:size)
    data_clone[:metadata] = data_clone[:metadata].sort if data_clone.key?(:metadata)
    if data_clone.key?(:playback) && data_clone[:playback].key?(:format)
      data_clone[:playback] = data_clone[:playback][:format].map{ |f| f.slice(*keys_formats).sort }.sort
    else
      data_clone[:playback] = []
    end
    data_clone[:end_time] = data_clone[:end_time].to_i if data_clone.key?(:end_time)
    data_clone[:start_time] = data_clone[:start_time].to_i if data_clone.key?(:start_time)
    data_clone = data_clone.slice(*keys)
    data_sorted = data_clone.sort

    # the data from the recording in the db
    attrs = recording.attributes.symbolize_keys.slice(*keys)
    attrs[:size] = attrs[:size].to_s if attrs.key?(:size)
    attrs[:metadata] = recording.metadata.pluck(:name, :content).map{ |i| [i[0].to_sym, i[1]] }.sort
    attrs[:playback] = recording.playback_formats.map{ |f|
      r = f.attributes.symbolize_keys.slice(*keys_formats)
      r[:type] = f.format_type
      r.sort
    }.sort
    attrs = attrs.sort

    # compare
    data_sorted.to_s != attrs.to_s
  end

  # Syncs the recordings in the db with the array of recordings in 'recordings',
  # as received from BigBlueButtonApi#get_recordings.
  # Will add new recordings that are not in the db yet and update the ones that
  # already are (matching by 'recordid'). Will NOT delete recordings from the db
  # if they are not in the array but instead mark them as unavailable.
  # 'server' is the BigbluebuttonServer object from which the recordings
  # were fetched.
  #
  # TODO: catch exceptions on creating/updating recordings
  def self.sync(server, recordings, full_sync=false)
    recordings.each do |rec|
      rec_obj = BigbluebuttonRecording.find_by_recordid(rec[:recordID])
      rec_data = adapt_recording_hash(rec)
      changed = !rec_obj.present? ||
                self.recording_changed?(rec_obj, rec_data)

      if changed
        BigbluebuttonRecording.transaction do
          if rec_obj
            logger.info "Sync recordings: updating recording #{rec_obj.inspect}"
            logger.debug "Sync recordings: recording data #{rec_data.inspect}"
            self.update_recording(server, rec_obj, rec_data)
          else
            logger.info "Sync recordings: creating recording"
            logger.debug "Sync recordings: recording data #{rec_data.inspect}"
            self.create_recording(server, rec_data)
          end
        end
      end
    end
    cleanup_playback_types

    # set as unavailable the recordings that are not in 'recordings', but
    # only in a full synchronization process, which means that the recordings
    # in `recordings` are *all* available in `server`, not a subset.
    if full_sync
      recordIDs = recordings.map{ |rec| rec[:recordID] }
      if recordIDs.length <= 0 # empty response
        BigbluebuttonRecording.
          where(available: true, server: server).
          update_all(available: false)
      else
        BigbluebuttonRecording.
          where(available: true, server: server).
          where.not(recordid: recordIDs).
          update_all(available: false)
      end
    end
  end

  protected

  # Adapt keys in 'hash' from bigbluebutton-api-ruby's (the way they are returned by
  # BigBlueButton's API) format to ours (more rails-like).
  def self.adapt_recording_hash(hash)
    new_hash = hash.clone
    mappings = {
      :recordID => :recordid,
      :meetingID => :meetingid,
      :startTime => :start_time,
      :endTime => :end_time
    }
    new_hash.keys.each { |k| new_hash[ mappings[k] ] = new_hash.delete(k) if mappings[k] }
    new_hash
  end

  def self.adapt_recording_users(original)
    if original.present? && original.size > 0
      users = original[:user]
      users = [users] unless users.is_a?(Array)
      users = users.map{ |u|
        id = u[:externalUserID]
        begin
          id = Integer(id)
        rescue
        end
        id
      }
      return users
    end
  end

  # Updates the BigbluebuttonRecording 'recording' with the data in the hash 'data'.
  # The format expected for 'data' follows the format returned by
  # BigBlueButtonApi#get_recordings but with the keys already converted to our format.
  def self.update_recording(server, recording, data)
    recording.server = server
    recording.room = BigbluebuttonRails.configuration.match_room_recording.call(data)
    recording.attributes = data.slice(:meetingid, :name, :published, :start_time, :end_time, :size)
    recording.available = true
    recording.recording_users = adapt_recording_users(data[:recordingUsers])
    recording.save!

    sync_additional_data(recording, data)
  end

  # Creates a new BigbluebuttonRecording with the data from 'data'.
  # The format expected for 'data' follows the format returned by
  # BigBlueButtonApi#get_recordings but with the keys already converted to our format.
  def self.create_recording(server, data)
    filtered = data.slice(:recordid, :meetingid, :name, :published, :start_time, :end_time, :size)
    recording = BigbluebuttonRecording.create(filtered)
    recording.available = true
    recording.room = BigbluebuttonRails.configuration.match_room_recording.call(data)
    recording.server = server
    recording.description = I18n.t('bigbluebutton_rails.recordings.default.description', :time => Time.at(recording.start_time).utc.to_formatted_s(:long))
    recording.meeting = BigbluebuttonRecording.find_matching_meeting(recording)
    recording.recording_users = adapt_recording_users(data[:recordingUsers])
    recording.save!

    sync_additional_data(recording, data)

    # new recording, get stats for the meeting
    if recording.meeting.present?
      Resque.enqueue(::BigbluebuttonGetStatsForMeetingWorker, recording.meeting.id, 2)
    end
  end

  # Syncs data that's not directly stored in the recording itself but in
  # associated models (e.g. metadata and playback formats).
  # The format expected for 'data' follows the format returned by
  # BigBlueButtonApi#get_recordings but with the keys already converted to our format.
  def self.sync_additional_data(recording, data)
    sync_metadata(recording, data[:metadata]) if data[:metadata]
    if data[:playback] and data[:playback][:format]
      sync_playback_formats(recording, data[:playback][:format])
    end
  end

  # Syncs the metadata objects of 'recording' with the data in 'metadata'.
  # The format expected for 'metadata' follows the format returned by
  # BigBlueButtonApi#get_recordings but with the keys already converted to our format.
  def self.sync_metadata(recording, metadata)
    # keys are stored as strings in the db
    received_metadata = metadata.clone.stringify_keys

    # get all metadata for this recording
    # note: it's a little slower than removing all metadata and adding again,
    # but it's cleaner to just update it and the loss of performance is small
    query = { owner_id: recording.id, owner_type: recording.class.to_s }
    metas = BigbluebuttonMetadata.where(query).all

    # batch insert all metadata
    columns = [ :id, :name, :content, :owner_id, :owner_type ]
    values = []
    received_metadata.each do |name, content|
      id = metas.select{ |m| m.name == name }.first.try(:id)
      values << [ id, name, content, recording.id, recording.class.to_s ]
    end
    BigbluebuttonMetadata.import! columns, values, validate: true,
                                  on_duplicate_key_update: [:name, :content]

    # delete all that doesn't exist anymore
    BigbluebuttonMetadata.where(query).where.not(name: received_metadata.keys).delete_all
  end

  # Syncs the playback formats objects of 'recording' with the data in 'formats'.
  # The format expected for 'formats' follows the format returned by
  # BigBlueButtonApi#get_recordings but with the keys already converted to our format.
  def self.sync_playback_formats(recording, formats)

    # clone and make it an array if it's a hash with a single format
    formats_copy = formats.clone
    formats_copy = [formats_copy] if formats_copy.is_a?(Hash)

    # remove all formats for this recording
    # note: easier than updating the formats because they don't have a clear key
    # to match by
    BigbluebuttonPlaybackFormat.where(recording_id: recording.id).delete_all

    # batch insert all playback formats
    columns = [ :recording_id, :url, :length , :playback_type_id ]
    values = []
    formats_copy.each do |format|
      unless format[:type].blank?
        playback_type = BigbluebuttonPlaybackType.find_by(identifier: format[:type])
        if playback_type.nil?
          downloadable = BigbluebuttonRails.configuration.downloadable_playback_types.include?(format[:type])
          attrs = {
            identifier: format[:type],
            visible: true,
            downloadable: downloadable
          }
          playback_type = BigbluebuttonPlaybackType.create!(attrs)
        end

        values << [ recording.id, format[:url], format[:length].to_i, playback_type.id ]
      end
    end
    BigbluebuttonPlaybackFormat.import! columns, values, validate: true
  end

  # Remove the unused playback types from the list.
  def self.cleanup_playback_types
    ids = BigbluebuttonPlaybackFormat.uniq.pluck(:playback_type_id)
    BigbluebuttonPlaybackType.destroy_all(['id NOT IN (?)', ids])
  end

  # Finds the BigbluebuttonMeeting that generated this recording. The meeting is searched using
  # the meetingid associated with this recording and the create time of the meeting, taken from
  # the recording's ID. There are some flexible clauses that try to match very close or truncated
  # timestamps from recordings start times to meeting create times.
  def self.find_matching_meeting(recording)
    meeting = nil
    unless recording.nil? #or recording.room.nil?
      unless recording.start_time.nil?
        start_time = recording.start_time
        meeting = BigbluebuttonMeeting.where("meetingid = ? AND create_time = ?", recording.meetingid, start_time).last
          if meeting.nil?
            meeting = BigbluebuttonMeeting.where("meetingid = ? AND create_time DIV 1000 = ?", recording.meetingid, start_time).last
          end
          if meeting.nil?
            div_start_time = (start_time/10)
            meeting = BigbluebuttonMeeting.where("meetingid = ? AND create_time DIV 10 = ?", recording.meetingid, div_start_time).last
          end
        logger.info "Recording: meeting found for the recording #{recording.inspect}: #{meeting.inspect}"
      end
    end

    meeting
  end

end
