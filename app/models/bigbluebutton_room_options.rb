require 'bigbluebutton_api'

class BigbluebuttonRoomOptions < ActiveRecord::Base
  include ActiveModel::ForbiddenAttributesProtection

  belongs_to :room, :class_name => 'BigbluebuttonRoom'
  validates :room_id, :presence => true

  def get_available_layouts
    ["Default", "Video Chat", "Meeting", "Webinar", "Lecture assistant", "Lecture"]
  end

  # Sets the attributes from the model into the config.xml passed in the arguments.
  # If anything was modified in the XML, returns the new XML generated as string.
  # Otherwise returns false.
  #
  # xml (string):: The config.xml in which the attributes will be set
  def set_on_config_xml(xml)
    config_xml = BigBlueButton::BigBlueButtonConfigXml.new(xml)
    config_xml.set_attribute("layout", "defaultLayout", self.default_layout, false)
    if config_xml.is_modified?
      config_xml.as_string
    else
      false
    end
  end

  # Returns true if any of the attributes was set. Is used to check whether the options
  # have to be sent to the server (setConfigXML) or not.
  def is_modified?
    !self.default_layout.nil?
  end
end