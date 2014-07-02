class WkMailer < ActionMailer::Base
layout 'mailer'
helper :application
include Redmine::I18n
  
	def sendRejectionEmail(loginuser,user,wktime,unitLabel,unit)
		set_language_if_valid(user.language)
		if !unitLabel.blank?
			subject="#{l(:label_wk_reject_expense)} #{wktime.begin_date}"
			body= l(:label_wk_expense_reject)
			total="#{l(:label_total)} #{l(:label_wkexpense)}  : #{unit} #{wktime.hours}"
		else
			subject=" #{l(:label_wk_reject_timesheet)} #{wktime.begin_date}"
			body= l(:label_wk_timesheet_reject)
			total="#{l(:label_total)} #{l(:field_hours)} : #{wktime.hours}"
		end

		body +="\n #{l(:field_name)} : #{user.firstname} #{user.lastname} \n #{total}"
		body +="\n #{l(:label_wk_submittedon)} : #{wktime.submitted_on} \n #{l(:label_wk_rejectedby)} : #{loginuser.firstname} #{loginuser.lastname}"
		body +="\n #{l(:label_wk_rejectedon)} : #{wktime.statusupdate_on} \n #{l(:label_wk_reject_reason)} : #{wktime.notes}"
		
		mail :from => loginuser.mail,:to => user.mail, :subject => subject,:body => body
	end
	  
	def nonSubmissionNotification(user,startDate)
		set_language_if_valid(user.language)
		
		subject = "#{l(:label_wk_nonsub_mail_subject)}" + " " + startDate.to_s
		body = !Setting.plugin_redmine_wktime['wktime_nonsub_mail_message'].blank? ? 
		Setting.plugin_redmine_wktime['wktime_nonsub_mail_message'] : "You are receiving this notification for timesheet non submission"
		body += "\n #{l(:label_wk_submission_deadline)}" + " : " + "#{day_name(Setting.plugin_redmine_wktime['wktime_submission_deadline'].to_i)}"
		body += "\n #{l(:field_name)} : #{user.firstname} #{user.lastname} "
		body += "\n #{ l(:label_week) }" + " : " + startDate.to_s + " - " + (startDate+6).to_s
		
		mail :from => Setting.mail_from ,:to => user.mail, :subject => subject,:body => body
	end
 end