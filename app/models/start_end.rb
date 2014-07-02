class StartEnd < ActiveRecord::Base
  unloadable

  attr_accessible :user_id, :startday, :start_1, :start_2, :start_3, :start_4, :start_5, :start_6, :start_7, :end_1, :end_2, :end_3, :end_4, :end_5, :end_6, :end_7, :pause_1, :pause_2, :pause_3, :pause_4, :pause_5, :pause_6, :pause_7

end
