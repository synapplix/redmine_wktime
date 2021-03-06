class WktimeController < ApplicationController
unloadable

include WktimeHelper

before_filter :require_login
before_filter :check_perm_and_redirect, :only => [:edit, :update]
before_filter :check_editperm_redirect, :only => [:destroy]
before_filter :check_view_redirect, :only => [:index]
before_filter :check_log_time_redirect, :only => [:new]

accept_api_auth :index, :edit, :update, :destroy

helper :custom_fields

  def submitAndRedirect

    update
    redirect_to :action => 'edit', :user_id => @user.id,         :startday => @startday-7,  :project_id => params[:project_id]
  end

  def index
   
  retrieve_date_range	
	@from = getStartDay(@from)
	@to = getEndDay(@to)
	# Paginate results
	user_id = params[:user_id]
	group_id = params[:group_id]
	set_user_projects
	if (!@manage_view_spenttime_projects.blank? && @manage_view_spenttime_projects.size > 0)
		@selected_project = getSelectedProject(@manage_view_spenttime_projects)
		setgroups 
	end
	ids = nil		
	if user_id.blank?
		ids = User.current.id.to_s
	elsif user_id.to_i == 0
		#all users
		userList=[]
		if group_id.blank?
			userList = Principal.member_of(@selected_project) 
		else
			userList = getMembers
		end
		userList.each_with_index do |users,i|
			if i == 0
				ids =  users.id.to_s
			else
				ids +=',' + users.id.to_s
			end
		end		
		ids = user_id if ids.nil?
	else
		ids = user_id
	end
	spField = getSpecificField()
	entityNames = getEntityNames()
	selectStr = "select v1.user_id, v1.startday as spent_on, v1." + spField
	wkSelectStr = selectStr + ", w.status "		
	sqlStr = " from "
	sDay = getDateSqlString('t.spent_on')
	#Martin Dube contribution: 'start of the week' configuration
	if ActiveRecord::Base.connection.adapter_name == 'SQLServer'	
		sqlStr += "(select  ROW_NUMBER() OVER (ORDER BY  " + sDay + " desc, user_id) AS rownum," + sDay + " as startday, "	
		sqlStr += " t.user_id, sum(t." + spField + ") as " + spField + " ,max(t.id) as id" + " from " + entityNames[1] + " t, users u" +
			" where u.id = t.user_id and u.id in (#{ids})"
		sqlStr += " and t.spent_on between '#{@from}' and '#{@to}'" unless @from.blank? && @to.blank?	
		sqlStr += " group by " + sDay + ", user_id ) as v1"
	else
		sqlStr += "(select " + sDay + " as startday, "
		sqlStr += " t.user_id, sum(t." + spField + ") as " + spField + " ,max(t.id) as id" + " from " + entityNames[1] + " t, users u" +
			" where u.id = t.user_id and u.id in (#{ids})"
		sqlStr += " and t.spent_on between '#{@from}' and '#{@to}'" unless @from.blank? && @to.blank?	
		sqlStr += " group by startday, user_id order by startday desc, user_id ) as v1"
	end		

	wkSqlStr = " left outer join " + entityNames[0] + " w on v1.startday = w.begin_date and v1.user_id = w.user_id"	
	status = params[:status]
	if !status.blank? && status != 'all'
		wkSqlStr += " WHERE w.status = '#{status}'" 
		if status == 'n'
			wkSqlStr += " OR  w.status IS NULL"
		end
	end
	
	findBySql(selectStr,sqlStr,wkSelectStr,wkSqlStr)
  #forwarding to new 
  redirect_to({ action: 'new'  })
  
  end
  
  def edit
  puts request.inspect
  @prev_template = false
	@new_custom_field_values = getNewCustomField
	setup
	findWkTE(@startday)
	@editable = @wktime.nil? || @wktime.status == 'n' || @wktime.status == 'r'
	@entries = findEntries()
	set_project_issues(@entries)
	if @entries.blank?
		@prev_entries = prevTemplate(@user.id)
		if !@prev_entries.blank?
			set_project_issues(@prev_entries)
			@prev_template = true
		end
	end
	respond_to do |format|
		format.html {
			render :layout => !request.xhr?
		} 
		format.api
	end
  end

  # called when save is clicked on the page
  def update
	setup	
	set_loggable_projects
	@wktime = nil
	errorMsg = nil
	respMsg = nil	
	findWkTE(@startday)
	@wktime = getWkEntity if @wktime.nil?
	allowApprove = false
	if api_request?
		errorMsg = gatherAPIEntries	
		errorMsg = validateMinMaxHr(@startday) if errorMsg.blank?
		total = @total		
		allowApprove = true if check_approvable_status		
	else
		total = params[:total].to_f
		gatherEntries
		allowApprove = true		
	end	
	errorMsg = gatherWkCustomFields(@wktime) if @wkvalidEntry && errorMsg.blank?
	wktimeParams = params[:wktime]
	cvParams = wktimeParams[:custom_field_values] unless wktimeParams.blank?	
	useApprovalSystem = (!Setting.plugin_redmine_wktime['wktime_use_approval_system'].blank? &&
							Setting.plugin_redmine_wktime['wktime_use_approval_system'].to_i == 1)
					
	@wktime.transaction do
		begin				
			if errorMsg.blank? && (!params[:wktime_save].blank? ||
				(!params[:wktime_submit].blank? && @wkvalidEntry && useApprovalSystem))		
				if !@wktime.nil? && ( @wktime.status == 'n' || @wktime.status == 'r')			
					@wktime.status = :n
					# save each entry
					entrycount=0
					entrynilcount=0
					@entries.each do |entry|
						entrycount += 1
						entrynilcount += 1 if (entry.hours).blank?
						allowSave = true
						if (!entry.id.blank? && !entry.editable_by?(@user))
							allowSave = false
						end						
						errorMsg = updateEntry(entry) if allowSave
						break unless errorMsg.blank?
					end				
					if !params[:wktime_submit].blank? && useApprovalSystem 
						@wktime.submitted_on = Date.today
						@wktime.submitter_id = User.current.id
						@wktime.status = :s					
						if !Setting.plugin_redmine_wktime['wktime_uuto_approve'].blank? &&
							Setting.plugin_redmine_wktime['wktime_uuto_approve'].to_i == 1
							@wktime.status = :a
						end
					end

						#Find the entry with the current user_id and startday
						#If there is no such entry create a new one 
						StartEnd.where(user_id: params[:user_id], startday: params[:startday]).first_or_create do |record|
						record.user_id = params[:user_id]
						record.startday = params[:startday]
						end
						#Select this entry                      
						n = StartEnd.where(user_id: params[:user_id], startday: params[:startday]).first
						#Set start_1...start_7
						n.start_1= params[:start_1]
						n.start_2= params[:start_2]
						n.start_3= params[:start_3]
						n.start_4= params[:start_4]
						n.start_5= params[:start_5]
						n.start_6= params[:start_6]
						n.start_7= params[:start_7]
						#analogue the values of end_1...end_7
						n.end_1= params[:end_1]
						n.end_2= params[:end_2]
						n.end_3= params[:end_3]
						n.end_4= params[:end_4]
						n.end_5= params[:end_5]
						n.end_6= params[:end_6]
						n.end_7= params[:end_7]
						#analogue the values of pause_1...pause_7
						n.pause_1= params[:pause_1]
						n.pause_2= params[:pause_2]
						n.pause_3= params[:pause_3]
						n.pause_4= params[:pause_4]
						n.pause_5= params[:pause_5]
						n.pause_6= params[:pause_6]
						n.pause_7= params[:pause_7]
						#Save the entry
						n.save
						#End added Code 3.3.2014
				end
				setTotal(@wktime,total)
				#if (errorMsg.blank? && total > 0.0)
				errorMsg = 	updateWktime if (errorMsg.blank? && ((!@entries.blank? && entrycount!=entrynilcount) || @teEntrydisabled))	
			end

			if errorMsg.blank? && useApprovalSystem
				if !@wktime.nil? && @wktime.status == 's'					
					if !params[:wktime_approve].blank? && allowApprove					 
						errorMsg = updateStatus(:a)
					elsif (!params[:wktime_reject].blank? || !params[:hidden_wk_reject].blank?) && allowApprove
						if api_request?
							teName = getTEName()
							if !params[:"wk_#{teName}"].blank? && !params[:"wk_#{teName}"][:notes].blank?
								@wktime.notes = params[:"wk_#{teName}"][:notes]
							end
						else
							@wktime.notes = params[:wktime_notes] unless params[:wktime_notes].blank?
						end
						errorMsg = updateStatus(:r)
						if email_delivery_enabled? 
							sendRejectionEmail
						end
					elsif !params[:wktime_unsubmit].blank?
						errorMsg = updateStatus(:n)
					end
				elsif !params[:wktime_unapprove].blank? && !@wktime.nil? && @wktime.status == 'a' && allowApprove
					errorMsg = updateStatus(:s)
				end
			end
		rescue Exception => e			
			errorMsg = e.message
		end
		
		if errorMsg.nil?			
			if !@entries.blank? || !params[:wktime_approve].blank? || 
				(!params[:wktime_reject].blank? || !params[:hidden_wk_reject].blank?) ||
				!params[:wktime_unsubmit].blank? || !params[:wktime_unapprove].blank? ||
				((!params[:wktime_submit].blank? || !cvParams.blank?) && total > 0.0 && @wkvalidEntry)						
				respMsg = l(:notice_successful_update)
			else
				respMsg = l(:error_wktime_save_nothing)
			end			
		else
			respMsg = l(:error_te_save_failed, :label => setEntityLabel, :error => errorMsg)
			raise ActiveRecord::Rollback
		end
	end
  	respond_to do |format|
		format.html {
			if errorMsg.nil?
				flash[:notice] = respMsg
				redirect_to :action => 'edit', :user_id => params[:user_id], :startday => @startday, :issue_assign_user => params[:issue_assign_user]  #mbraeu contribution: keep configuration of issue_assigned_user
			else
				flash[:error] = respMsg
				if !params[:enter_issue_id].blank? && params[:enter_issue_id].to_i == 1					
				redirect_to :action => 'edit', :user_id => params[:user_id], :startday => @startday,
				:enter_issue_id => 1	
				else
					redirect_to :action => 'edit', :user_id => params[:user_id], :startday => @startday
				end
			end
		}
		format.api{
			if errorMsg.blank?
				render :text => respMsg, :layout => nil
			else			
				@error_messages = respMsg.split('\n')	
				render :template => 'common/error_messages.api', :status => :unprocessable_entity, :layout => nil
			end
		}
	end  
  end
	
	def deleterow
		if check_editPermission
			ids = params['ids']
			delete(ids)
			respond_to do |format|
				format.text  { 
					render :text => 'OK' 
				}
			end
		else
			respond_to do |format|
				format.text  { 
					render :text => 'FAILED' 
				}
			end
		end
	end

	def destroy
		setup
		#cond = getCondition('spent_on', @user.id, @startday, @startday+6)
		#TimeEntry.delete_all(cond)
		@entries = findEntries()
		@entries.each do |entry|
			entry.destroy()
		end
		cond = getCondition('begin_date', @user.id, @startday)
		deleteWkEntity(cond)
		respond_to do |format|
			format.html {				
				flash[:notice] = l(:notice_successful_delete)
				redirect_back_or_default :action => 'index', :tab => params[:tab]
			} 
			format.api  {
				render_api_ok
			}
		end
	end
	
	def new
		set_user_projects
		@selected_project = getSelectedProject(@manage_log_time_projects)
		# get the startday for current week
  @startday = getStartDay(Date.today)    
  render :action => 'new'
	end
		
	def getIssueAssignToUsrCond
		issueAssignToUsrCond=nil
		if (!params[:issue_assign_user].blank? && params[:issue_assign_user].to_i == 1) 
			issueAssignToUsrCond ="and (#{Issue.table_name}.assigned_to_id=#{params[:user_id]} OR #{Issue.table_name}.author_id=#{params[:user_id]})" 
		end
		issueAssignToUsrCond
	end
	
	def getissues
	projectids = []
	if !params[:term].blank? 
		 subjectPart = (params[:term]).to_s.strip
		set_loggable_projects
		@logtime_projects.each do |project|
			projectids << project.id
		end
	end		
	issueAssignToUsrCond = getIssueAssignToUsrCond
	trackerIDCond=nil
	trackerid=nil
	#If click addrow or project changed, tracker list does not show, get tracker value from settings page  
	if  !filterTrackerVisible() && (params[:tracker_id].blank? || !params[:term].blank?)
		params[:tracker_id] = Setting.plugin_redmine_wktime[getTFSettingName()]
		trackerIDCond= "AND #{Issue.table_name}.tracker_id in(#{(Setting.plugin_redmine_wktime[getTFSettingName()]).join(',')})" if !params[:tracker_id].blank? && params[:tracker_id] != ["0"]
	end	
	if Setting.plugin_redmine_wktime['wktime_closed_issue_ind'].to_i == 1
		if !params[:tracker_id].blank? && params[:tracker_id] != ["0"] && params[:term].blank?
			issues = Issue.find_all_by_project_id(params[:project_id] || params[:project_ids] , 
			:conditions =>  ["#{Issue.table_name}.tracker_id in ( ?) #{issueAssignToUsrCond}", params[:tracker_id]] , :order => 'project_id')	
		elsif !params[:term].blank? 
			  	if subjectPart.present?
					if subjectPart.match(/^\d+$/)						
						cond = ["(LOWER(#{Issue.table_name}.subject) LIKE ? OR #{Issue.table_name}.id=?)#{issueAssignToUsrCond} #{trackerIDCond}", "%#{subjectPart.downcase}%","#{subjectPart.to_i}"]
						else
						cond = ["LOWER(#{Issue.table_name}.subject) LIKE ? #{issueAssignToUsrCond}#{trackerIDCond}", "%#{subjectPart.downcase}%"]
					end
					issues = Issue.find_all_by_project_id(params[:project_id] || params[:project_ids] || projectids ,
					:conditions => cond , :order => 'project_id')	
				end  
		else
			if (!params[:issue_assign_user].blank? && params[:issue_assign_user].to_i == 1) 
				issues = Issue.find_all_by_project_id(params[:project_id] || params[:project_ids]|| projectids,:conditions =>["(#{Issue.table_name}.assigned_to_id= ? OR #{Issue.table_name}.author_id= ?)#{trackerIDCond}", params[:user_id],params[:user_id]], :order => 'project_id')
			else
				issues = Issue.find_all_by_project_id(params[:project_id] || params[:project_ids], :order => 'project_id')
			end
		end
	else	
		@startday = params[:startday].to_s.to_date	
		
		if !params[:tracker_id].blank? && params[:tracker_id] != ["0"]	&& params[:term].blank?	

			cond = ["(#{IssueStatus.table_name}.is_closed = ? OR #{Issue.table_name}.updated_on >= ?) AND  #{Issue.table_name}.tracker_id in ( ?) #{issueAssignToUsrCond}", false, @startday,params[:tracker_id]]			
		elsif !params[:term].blank? 
			if subjectPart.present?
				if subjectPart.match(/^\d+$/)					
					cond = ["(LOWER(#{Issue.table_name}.subject) LIKE ? OR #{Issue.table_name}.id=?)  AND #{IssueStatus.table_name}.is_closed = ? #{issueAssignToUsrCond} #{trackerIDCond}", "%#{subjectPart.downcase}%","#{subjectPart.to_i}",false]
				else
					cond = ["(LOWER(#{Issue.table_name}.subject) LIKE ?  AND #{IssueStatus.table_name}.is_closed = ?) #{issueAssignToUsrCond} #{trackerIDCond}", "%#{subjectPart.downcase}%",false]
				end				
			 end  
		else
		
			cond =["(#{IssueStatus.table_name}.is_closed = ? OR #{Issue.table_name}.updated_on >= ?) #{issueAssignToUsrCond}#{trackerIDCond}", false, @startday]
		end	
		
		issues= Issue.find_all_by_project_id(params[:project_id] || params[:project_ids] || projectids,
		:conditions => cond,		
		:include => :status, :order => 'project_id')
	end
	 issues.compact!
	user = User.find(params[:user_id])

		if  !params[:format].blank?
			respond_to do |format|
				format.text  { 
					issStr =""
					issues.each do |issue|
					issStr << issue.project_id.to_s() + '|' + issue.id.to_s() + '|' + issue.tracker.to_s() +  '|' + 
							issue.subject  + "\n" if issue.visible?(user)
					end	
				render :text => issStr 
				}	
			end
		else 
			issStr=[]
			issues.each do |issue|            
				issStr << {:value => issue.id.to_s(), :label => issue.tracker.to_s() +  " #" + issue.id.to_s() + ": " + issue.subject }  if issue.visible?(user)
			end 
			
			render :json => issStr 
		end
	end
 
	def getactivities
		project = nil
		error = nil
		project_id = params[:project_id]
		if !project_id.blank?
			project = Project.find(project_id)
		elsif !params[:issue_id].blank?
			issue = Issue.find(params[:issue_id])
			project = issue.project
			project_id = project.id
			u_id = params[:user_id]
			user = User.find(u_id)
			if !user_allowed_to?(:log_time, project)
				error = "403"
			end
		else
			error = "403"
		end
		actStr =""
		project.activities.each do |a|
			actStr << project_id.to_s() + '|' + a.id.to_s() + '|' + a.name + "\n"
		end
	
		respond_to do |format|
			format.text  { 
			if error.blank?
				render :text => actStr 
			else
				render_403
			end
			}
		end
	end
	
	def getusers
		project = Project.find(params[:project_id])
		userStr =""
		project.members.each do |m|
			userStr << m.user_id.to_s() + ',' + m.name + "\n"
		end
	
		respond_to do |format|
			format.text  { render :text => userStr }
		end
	end

  # Export wktime to a single pdf file
  def export
    respond_to do |format|
		@new_custom_field_values = getNewCustomField
		@entries = findEntries()
		findWkTE(@startday)
		unitLabel = getUnitLabel
		format.pdf {
			send_data(wktime_to_pdf(@entries, @user, @startday,unitLabel), :type => 'application/pdf', :filename => "#{@startday}-#{params[:user_id]}.pdf")
		}
		format.csv {
			send_data(wktime_to_csv(@entries, @user, @startday,unitLabel), :type => 'text/csv', :filename => "#{@startday}-#{params[:user_id]}.csv")
      }
    end
  end 
  
  def getLabelforSpField
	l(:field_hours)
  end
  
  def getCFInRowHeaderHTML
    "wktime_cf_in_row_header"
  end
  
  def getCFInRowHTML
    "wktime_cf_in_row"
  end
  
    
	def getTFSettingName
		"wktime_issues_filter_tracker"
	end
	
	def filterTrackerVisible
		!Setting.plugin_redmine_wktime['wktime_allow_user_filter_tracker'].blank?  && Setting.plugin_redmine_wktime['wktime_allow_user_filter_tracker'].to_i == 1
	end  
 
	def getUnit(entry)
		nil
	end
	
	def getUnitDDHTML
		nil
	end
	
	def getUnitLabel
		nil
	end
	
	def showWorktimeHeader
		!Setting.plugin_redmine_wktime['wktime_work_time_header'].blank? &&
		Setting.plugin_redmine_wktime['wktime_work_time_header'].to_i == 1
	end
	
	def maxHour
		Setting.plugin_redmine_wktime['wktime_restr_max_hour'].to_i == 1 ?  
		(Setting.plugin_redmine_wktime['wktime_max_hour_day'].blank? ? 8 : Setting.plugin_redmine_wktime['wktime_max_hour_day']) : 0
	end
	def minHour
		Setting.plugin_redmine_wktime['wktime_restr_min_hour'].to_i == 1 ?  
		(Setting.plugin_redmine_wktime['wktime_min_hour_day'].blank? ? 0 : Setting.plugin_redmine_wktime['wktime_min_hour_day']) : 0
	end
	
	def total_all(total)
		html_hours(l_hours(total))
	end
	
	 def getStatus	
		status = getTimeEntryStatus(params[:startDate].to_date,User.current.id)	
		respond_to do |format|
			format.text  { render :text => status }
		end	
	end

	def setLimitAndOffset		
		if api_request?
			@offset, @limit = api_offset_and_limit
			if !params[:limit].blank?
				@limit = params[:limit]
			end
			if !params[:offset].blank?
				@offset = params[:offset]
			end
		else
			@entry_pages = Paginator.new self, @entry_count, per_page_option, params['page']
			@limit = @entry_pages.items_per_page
			@offset = @entry_pages.current.offset
		end	
	end
	
	def getMembersbyGroup
		group_by_users=""
		userList=[]
		set_managed_projects
		userList = getMembers
		userList.each do |users|
			group_by_users << users.id.to_s() + ',' + users.name + "\n"
		end
		respond_to do |format|
			format.text  { render :text => group_by_users }
		end
	end	
	
	def findTEProjects()		
		entityNames = getEntityNames	
		Project.find_by_sql("SELECT DISTINCT p.* FROM projects p INNER JOIN " + entityNames[1] + " t ON p.id=t.project_id  where t.spent_on BETWEEN '" + @startday.to_s +
				"' AND '" +  (@startday+6).to_s + "' AND t.user_id = " + @user.id.to_s)		
	end
	
	def check_approvable_status		
		te_projects=[]
		if !@entries.blank?		
			@te_projects = @entries.collect{|entry| entry.project}.uniq
			te_projects = @approvable_projects & @te_projects if !@te_projects.blank?			
		end	
		(!te_projects.blank? && (@user.id != User.current.id ||(!Setting.plugin_redmine_wktime[:wktime_own_approval].blank? && 
							Setting.plugin_redmine_wktime[:wktime_own_approval].to_i == 1 )))? true: false
	end
	
private
	
	def getUsersbyGroup
		groupusers= nil
		scope=User.in_group(params[:group_id])  if params[:group_id].present?
		groupusers =scope.all
	end
	
	def getMembers
		projMembers = []
		groupbyusers=[]
		groupusers = getUsersbyGroup
		projMembers = Principal.member_of(@manage_view_spenttime_projects)
		groupbyusers = groupusers & projMembers
	end
	
	def getCondition(date_field, user_id, start_date, end_date=nil)
		cond = nil
		if end_date.nil?
			cond = user_id.nil? ? [ date_field + ' = ?', start_date] :
				[ date_field + ' = ? AND user_id = ?', start_date, user_id]
		else
			cond = user_id.nil? ? [ date_field + ' BETWEEN ? AND ?', start_date, end_date] :
			[ date_field + ' BETWEEN ? AND ? AND user_id = ?', start_date, end_date, user_id]
		end
		return cond
	end	
	
	#change the date to a last day of week
	def getEndDay(date)
		start_of_week = getStartOfWeek
		#Martin Dube contribution: 'start of the week' configuration
		unless date.nil?
			daylast_diff = (6 + start_of_week) - date.wday
			date += (daylast_diff%7)
		end
		date
	end
	
	def prevTemplate(user_id)	
		prev_entries = nil       
    noOfWeek = (Setting.plugin_redmine_wktime['wktime_previous_template_week'].to_i)*7
       
     if !noOfWeek.blank?
       entityNames = getEntityNames       
  

       #changed SQL Query
      sqlStr = "select * "+
      "from "  + entityNames[1] + ', projects as p' +
      " where "+ entityNames[1] +"." +"user_id = "+ user_id.to_s +
      " and  `spent_on`  >= '" + (@startday-noOfWeek).to_s + "'" +
      " and  `spent_on`  <= '" + @startday.to_s + "'" +
      " and   `project_id` = p.id" +
      " order by p.name asc"
           
      #sqlStr = "select t.* from " + entityNames[1] + " t inner join ( "
      #if ActiveRecord::Base.connection.adapter_name == 'SQLServer'   
      #    sqlStr += "select TOP " + noOfWeek.to_s + sDay + " as startday" +
      #        " from  " + entityNames[1] + " t where user_id = " + user_id.to_s +
      #        " group by " + sDay + " order by startday desc ) as v"
      #       
           
      #if ActiveRecord::Base.connection.adapter_name == 'SQLServer'
      #  sqlStr += "select TOP " + noOfWeek.to_s + sDay + " as startday" +
      #    " from  " + entityNames[1] + " t where user_id = " + user_id.to_s + "and" + @startday + "t.startday" +
      #    " group by " + sDay + " order by startday desc ) as v"
           
           
      #else
      #    sqlStr += "select " + sDay + " as startday" +
      #            " from  " + entityNames[1] + " t where user_id = " + user_id.to_s +
      #            " group by startday order by startday desc limit " + noOfWeek.to_s + ") as v"
      #end
      #       
      #sqlStr +=" on " + sDay + " = v.startday where user_id = " + user_id.to_s +
      #        " order by t.project_id, t.issue_id, t.activity_id"               
      #   
                           
      prev_entries = TimeEntry.find_by_sql(sqlStr)
      end
      prev_entries
    end

	
  def gatherEntries
 		entryHash = params[:time_entry]
		@entries ||= Array.new
		custom_values = Hash.new
		#setup
		decimal_separator = l(:general_csv_decimal_separator)
		use_detail_popup = !Setting.plugin_redmine_wktime['wktime_use_detail_popup'].blank? &&
			Setting.plugin_redmine_wktime['wktime_use_detail_popup'].to_i == 1
		custom_fields = TimeEntryCustomField.find(:all)
		@wkvalidEntry=false
		@teEntrydisabled=false
		unless entryHash.nil?
			entryHash.each_with_index do |entry, i|
				if !entry['project_id'].blank?
					hours = params['hours' + (i+1).to_s()]
					ids = params['ids' + (i+1).to_s()]
					comments = params['comments' + (i+1).to_s()]
					disabled = params['disabled' + (i+1).to_s()]
					@wkvalidEntry=true	
					if use_detail_popup
						custom_values.clear
						custom_fields.each do |cf|
							custom_values[cf.id] = params["_custom_field_values_#{cf.id}" + (i+1).to_s()]
						end
					end
					
					j = 0
					ids.each_with_index do |id, k|
						if disabled[k] == "false"
							if(!id.blank? || !hours[j].blank?)
								teEntry = nil
								teEntry = getTEEntry(id)
								teEntry.attributes = entry
								# since project_id and user_id is protected
								teEntry.project_id = entry['project_id']
								teEntry.user_id = @user.id
								teEntry.spent_on = @startday + k
								#for one comment, it will be automatically loaded into the object
								# for different comments, load it separately
								unless comments.blank?
									teEntry.comments = comments[k].blank? ? nil : comments[k]	
								end
								#timeEntry.hours = hours[j].blank? ? nil : hours[j].to_f
								#to allow for internationalization on decimal separator
								setValueForSpField(teEntry,hours[j],decimal_separator,entry)

								unless custom_fields.blank?
									teEntry.custom_field_values.each do |custom_value|
										custom_field = custom_value.custom_field

										#if it is from the row, it should be automatically loaded
										if !((!Setting.plugin_redmine_wktime['wktime_enter_cf_in_row1'].blank? &&
											Setting.plugin_redmine_wktime['wktime_enter_cf_in_row1'].to_i == custom_field.id) ||
											(!Setting.plugin_redmine_wktime['wktime_enter_cf_in_row2'].blank? &&
											Setting.plugin_redmine_wktime['wktime_enter_cf_in_row2'].to_i == custom_field.id))
											if use_detail_popup
												cvs = custom_values[custom_field.id]
												custom_value.value = cvs[k].blank? ? nil : 
												custom_field.multiple? ? cvs[k].split(',') : cvs[k]	
											end
										end
									end
								end

								@entries << teEntry
							end
							j += 1
						else
							@teEntrydisabled=true
						end			
					end
				end
			end
		end
  end
  
	def gatherWkCustomFields(wktime)
		errorMsg = nil
		cvParams = nil
		if api_request?
			teName = getTEName()
			wktimeParams = params[:"wk_#{teName}"][:custom_fields]		
			cvParams = getAPIWkCustomFields(wktimeParams)	unless wktimeParams.blank?				
		else
			wktimeParams = params[:wktime]
			cvParams = wktimeParams[:custom_field_values] unless wktimeParams.blank?
		end		
		#custom_values = Hash.new
		custom_fields = WktimeCustomField.find(:all)		
		if !custom_fields.blank? && !cvParams.blank?
			wktime.custom_field_values.each do |custom_value|
				custom_field = custom_value.custom_field				
				cvs = cvParams["#{custom_field.id}"]	
				if cvs.blank? && custom_field.is_required				
					errorMsg = "#{custom_field.name} #{l('activerecord.errors.messages.blank')} "
					break
				end								
				custom_value.value = cvs.blank? ? nil : 
					custom_field.multiple? ? cvs.split(',') : cvs
			end
		end
		return errorMsg
	end
	
	def getAPIWkCustomFields(wktimeParams)		
		wkCustField = wktimeParams
		custFldValues = nil
		if !wkCustField.blank?
			custFldValues = Hash.new
			wkCustField.each do |cf|		
				custFldValues["#{cf[:id]}"] = cf[:value]
			end
		end
		custFldValues
	end	

	def gatherAPIEntries
		errorMsg = nil
		wkte_entries = Hash.new
		teName = getTEName()
		entityNames = getEntityNames()		
		@entries = Array.new
		decimal_separator = l(:general_csv_decimal_separator)
		@total = 0
		spField = getSpecificField()
		createSpentOnHash(@startday)
		@wkvalidEntry = true
		@teEntrydisabled=true		
		begin
		wkte_entries = params[:"wk_#{teName}"][:"#{entityNames[1]}"]
		if !wkte_entries.blank?
			wkte_entries.each do |entry|			
				if !entry[:"#{spField}"].blank?
					id = entry[:id]
					teEntry = nil
					teEntry = getTEEntry(id)									
					teEntry.safe_attributes = entry				
					if (!entry[:user].blank? && !entry[:user][:id].blank? && @user.id != entry[:user][:id].to_i)
						raise "#{l(:field_user)} #{l('activerecord.errors.messages.invalid')}"
					else
						teEntry.user_id = @user.id
					end
					if !@hrPerDay.has_key?(entry[:spent_on])
						raise "#{l(:label_date)} #{l('activerecord.errors.messages.invalid')}"
					end
					teEntry.project_id = entry[:project][:id] if !entry[:project].blank?
					if (Setting.plugin_redmine_wktime['wktime_allow_blank_issue'].blank? && (entry[:issue].blank? || entry[:issue][:id].blank?))
						raise "#{l(:field_issue)} #{l('activerecord.errors.messages.blank')} "
					else
						if !entry[:issue].blank? && !entry[:issue][:id].blank?
							teEntry.issue_id = entry[:issue][:id]
						else
							teEntry.issue_id = nil
						end
					end
					teEntry.activity_id = entry[:activity][:id] if !entry[:activity].blank?						
					setValueForSpField(teEntry,(entry[:"#{spField}"].to_s),decimal_separator,entry)
					@hrPerDay[entry[:spent_on]] = "#{@hrPerDay[entry[:spent_on]]}".to_f + (entry[:"#{spField}"].to_s).gsub(decimal_separator, '.').to_f
					@total = @total + (entry[:"#{spField}"].to_s).gsub(decimal_separator, '.').to_f
					@entries << teEntry
				end
			end
		end
		rescue Exception => e		
			errorMsg = e.message
		end
		errorMsg
	end
	
	def findEntries
		setup	
		cond = getCondition('spent_on', @user.id, @startday, @startday+6, )		
		findEntriesByCond(cond)
	end
	
	def findWkTE(start_date, end_date=nil)
		setup
		cond = getCondition('begin_date', @user.nil? ? nil : @user.id, start_date, end_date)
		findWkTEByCond(cond)		
		@wktime = @wktimes[0] unless @wktimes.blank? 
	end
	
	def findWkTEHash(start_date, end_date)
		@wktimesHash ||= Hash.new
		@wktimesHash.clear
		findWkTE(start_date, end_date)		
		@wktimes.each do |wktime|
			@wktimesHash[wktime.user_id.to_s + wktime.begin_date.to_s] = wktime
		end
	end
	
	def startTimeExists
	 if (CustomField.where(name: 'Startzeitpunkt').nil?) 
	   then $x = false
	 else $x = true
	 end
	end
	
	def render_edit
		set_user_projects
		render :action => 'edit', :user_id => params[:user_id], :startday => @startday
	end
	
  def check_perm_and_redirect
    unless check_permission
      render_403
      return false
    end
  end
  
  def user_allowed_to?(privilege, entity)
	setup
	return @user.allowed_to?(privilege, entity)
  end
  
  def can_log_time?(project_id)
	ret = false
	set_loggable_projects
	@logtime_projects.each do |lp|
		if lp.id == project_id
			ret = true
			break
		end
	end
	return ret
  end
  
  def check_permission
    ret = false;
	set_user_projects
	
	if !@manage_log_time_projects.blank? && @manage_log_time_projects.size > 0
		#for manager
	   if !@logtime_projects.blank? && @logtime_projects.size > 0
			manage_log_projects = @manage_log_time_projects & @logtime_projects
			ret = (!manage_log_projects.blank? && manage_log_projects.size > 0)
		end
	else
		#for individuals
		ret = (@user.id == User.current.id && @logtime_projects.size > 0)
	end
    return ret
	
  end
  
    def check_editperm_redirect
		unless check_editPermission
			render_403
			return false
		end
	end
  
    def check_editPermission
		allowed = true;
		ids = params['ids']
		if !ids.blank?
			@entries = findTEEntries(ids)
		else		
			setup
			cond = getCondition('spent_on', @user.id, @startday, @startday+6)
			@entries = findEntriesByCond(cond)
		end
		@entries.each do |entry|
			if(!entry.editable_by?(User.current))
				allowed = false
				break
			end
		end
		return allowed
	end
	
	def updateEntry(entry)
		errorMsg = nil
		if entry.hours.blank?
			# delete the time_entry
			# if the hours is empty but id is valid
			# entry.destroy() unless ids[i].blank?
			if !entry.id.blank?
				if !entry.destroy()
					errorMsg = entry.errors.full_messages.join('\n')
				end
			end
		else
			#if id is there it should be update otherwise create
			#the UI disables editing of
			if can_log_time?(entry.project_id) 
				if !entry.save()
					errorMsg = entry.errors.full_messages.join('\n')
				end
			else
				errorMsg = l(:error_not_permitted_save)
			end
		end
		return errorMsg
	end
	  
	def updateWktime
		errorMsg = nil
		@wktime.begin_date = @startday
		@wktime.user_id = @user.id
		@wktime.statusupdater_id = User.current.id
		@wktime.statusupdate_on = Date.today
		if !@wktime.save()
			errorMsg = @wktime.errors.full_messages.join('\n')
		end
		return errorMsg
	end

	# update timesheet status
	def updateStatus(status)
		errorMsg = nil
		if @wktimes.blank? 
			errorMsg = l(:error_wktime_save_nothing)
		else	
			@wktime.statusupdater_id = User.current.id
			@wktime.statusupdate_on = Date.today
			@wktime.status = status
			if !@wktime.save()
				errorMsg = @wktime.errors.full_messages.join('\n')
			end
		end
		return errorMsg
	end	

	# delete a timesheet
	def deleteWktime
		errorMsg = nil
		unless @wktime.nil? 
			if !@wktime.destroy()
				errorMsg = @wktime.errors.full_messages.join('\n')
			end
		end
		return errorMsg
	end		
	
  # Retrieves the date range based on predefined ranges or specific from/to param dates
  def retrieve_date_range
    @free_period = false
    @from, @to = nil, nil

    if params[:period_type] == '1' || (params[:period_type].nil? && !params[:period].nil?)
      case params[:period].to_s
      when 'today'
        @from = @to = Date.today
      when 'yesterday'
        @from = @to = Date.today - 1
      when 'current_week'
        @from = getStartDay(Date.today - (Date.today.cwday - 1)%7)
        @to = @from + 6
      when 'last_week'
        @from =getStartDay(Date.today - 7 - (Date.today.cwday - 1)%7)
	    @to = @from + 6
      when '7_days'
        @from = Date.today - 7
        @to = Date.today
      when 'current_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1)
        @to = (@from >> 1) - 1
      when 'last_month'
        @from = Date.civil(Date.today.year, Date.today.month, 1) << 1
        @to = (@from >> 1) - 1
      when '30_days'
        @from = Date.today - 30
        @to = Date.today
      when 'current_year'
        @from = Date.civil(Date.today.year, 1, 1)
        @to = Date.civil(Date.today.year, 12, 31)
      end
    elsif params[:period_type] == '2' || (params[:period_type].nil? && (!params[:from].nil? || !params[:to].nil?))
      begin; @from = params[:from].to_s.to_date unless params[:from].blank?; rescue; end
      begin; @to = params[:to].to_s.to_date unless params[:to].blank?; rescue; end
      @free_period = true
    else
      # default
	  # 'current_month'		
        @from = Date.civil(Date.today.year, Date.today.month, 1)
        @to = (@from >> 1) - 1
    end    
    
    @from, @to = @to, @from if @from && @to && @from > @to

  end  

	# show all groups and project/group members show
	def setgroups
		@groups = Group.sorted.all
		@members = Array.new
		if params[:projgrp_type] == '2'
			userLists=[]
			userLists = getMembers
			@use_group=true
			userLists.each do |users|
				@members << [users.name,users.id.to_s()]
			end
		else
			@use_group=false			
			@members=@selected_project.members.collect{|m| [ m.name, m.user_id ] }
		end
	end
	
  	def setup
		teName = getTEName()
		if api_request? && params[:startday].blank?
			startday = params[:"wk_#{teName}"][:startday].to_s.to_date
		else
			startday = params[:startday].to_s.to_date				
		end
		if api_request? && params[:user_id].blank?
			user_id = params[:"wk_#{teName}"][:user][:id]		
		else
			user_id = params[:user_id]			
		end
		# if user has changed the startday
		@startday ||= getStartDay(startday)
		@user ||= User.find(user_id)
	end
  
	def set_user_projects
		set_managed_projects
		set_loggable_projects		
		set_approvable_projects
	end
	
	def set_managed_projects
		@manage_projects ||= Project.find(:all, :order => 'name', 
			:conditions => Project.allowed_to_condition(User.current, :manage_members))		
		@manage_projects =	setTEProjects(@manage_projects)	
		
		# @manage_view_spenttime_projects contains project list of current user with manage_member and view_time_entries permission
		# @manage_view_spenttime_projects is used to fill up the dropdown in list page for managers		
		view_spenttime_projects ||= Project.find(:all, :order => 'name', 
			:conditions => Project.allowed_to_condition(User.current, :view_time_entries))
		@manage_view_spenttime_projects = @manage_projects & view_spenttime_projects
		@manage_view_spenttime_projects = setTEProjects(@manage_view_spenttime_projects)
    
		# @currentUser_loggable_projects contains project list of current user with log_time permission
		# @currentUser_loggable_projects is used to show/hide new time/expense sheet link	
		@currentUser_loggable_projects ||= Project.find(:all, :order => 'name', 
			:conditions => Project.allowed_to_condition(User.current, :log_time))
		@currentUser_loggable_projects = setTEProjects(@currentUser_loggable_projects)
		
		# @manage_log_time_projects contains project list of current user with manage_member and log_time permission
		# @manage_log_time_projects is used to fill up the dropdown in new page for managers
		@manage_log_time_projects = @manage_projects & @currentUser_loggable_projects
		@manage_log_time_projects = setTEProjects(@manage_log_time_projects)
		$user_project = @manage_log_time_projects 
	end

	def set_loggable_projects
	 	if api_request? && params[:user_id].blank?
			teName = getTEName()
			u_id = params[:"wk_#{teName}"][:user][:id]
		else
			u_id = params[:user_id]
		end
		if !u_id.blank?	&& u_id.to_i != 0
			@user ||= User.find(u_id)	
			@logtime_projects ||= Project.find(:all, :order => 'name', 
				:conditions => Project.allowed_to_condition(@user, :log_time))
			@logtime_projects = setTEProjects(@logtime_projects)			
		end
	end
	
	
	def set_project_issues(entries)
		@projectIssues ||= Hash.new
		@projActivities ||= Hash.new
		@projectIssues.clear
		@projActivities.clear
		entries.each do |entry|
			set_visible_issues(entry)
		end
		#load the first project in the list also
		set_visible_issues(nil)
	end

	def set_visible_issues(entry)

				if (!entry.nil?)
					#Select project from entry
					project = entry.project
					project_id = entry.project_id
				else
					#Select default project
					projects = User.current.memberships.collect(&:project).compact.select(&:active?).uniq if entry.nil?
					projects = options_for_wktime_project(projects) #@currentUser_loggable_projects
					project = projects.detect {|p| p[1].to_i == entry.project_id} unless entry.nil?
					projects.unshift( [ entry.project_id, entry.project_id ] ) 	if !entry.nil? && project.blank?
					project_id = projects[0][1]
				end

		issueAssignToUsrCond = getIssueAssignToUsrCond
        if @projectIssues[project_id].blank?
            allIssues = Array.new
            if Setting.plugin_redmine_wktime['wktime_closed_issue_ind'].to_i == 1                
                if !Setting.plugin_redmine_wktime[getTFSettingName()].blank? &&  Setting.plugin_redmine_wktime[getTFSettingName()] != ["0"]
					cond=["#{Issue.table_name}.tracker_id in ( ?) #{issueAssignToUsrCond} ",Setting.plugin_redmine_wktime[getTFSettingName()]]
                    #allIssues = Issue.find_all_by_project_id(project_id , :conditions =>  ["#{Issue.table_name}.tracker_id in ( ?) ",Setting.plugin_redmine_wktime[getTFSettingName()]])    
					allIssues = Issue.find_all_by_project_id(project_id,:conditions =>cond) 
                else
					if (!params[:issue_assign_user].blank? && params[:issue_assign_user].to_i == 1) 
						allIssues = Issue.find_all_by_project_id(project_id,:conditions =>["(#{Issue.table_name}.assigned_to_id= ? OR #{Issue.table_name}.author_id= ?)", params[:user_id],params[:user_id]]) 
					else
						allIssues = Issue.find_all_by_project_id(project_id) 
					end
                end
          	else
                if !Setting.plugin_redmine_wktime[getTFSettingName()].blank? &&  Setting.plugin_redmine_wktime[getTFSettingName()] != ["0"]
                     cond = ["(#{IssueStatus.table_name}.is_closed = ? OR #{Issue.table_name}.updated_on >= ?) AND  #{Issue.table_name}.tracker_id in ( ?) #{issueAssignToUsrCond} ",false, @startday,Setting.plugin_redmine_wktime[getTFSettingName()]]
                else
                    cond =["(#{IssueStatus.table_name}.is_closed = ? OR #{Issue.table_name}.updated_on >= ?) #{issueAssignToUsrCond}",false, @startday]
                end
                allIssues = Issue.find_all_by_project_id(project_id,
                :conditions => cond,
                :include => :status)
                   
            end
            # find the issues which are visible to the user            
            @projectIssues[project_id] = allIssues.select {
            	|i| i.visible?(@user)   
            }
        end
        if @projActivities[project_id].blank?
            @projActivities[project_id] = project.activities unless project.nil?
        end 
    end
	
	def getSpecificField		
		"hours"
	end
	
	def getEntityNames
		["#{Wktime.table_name}", "#{TimeEntry.table_name}"]
	end
	
	def findBySql(selectStr,sqlStr,wkSelectStr,wkSqlStr)
		spField = getSpecificField()
		result = TimeEntry.find_by_sql("select count(*) as id from (" + selectStr + sqlStr + ") as v2")
		@entry_count = result[0].id
        setLimitAndOffset()		
		rangeStr = formPaginationCondition()		
		@entries = TimeEntry.find_by_sql(wkSelectStr + sqlStr + wkSqlStr + rangeStr)
		@unit = nil	
        #@total_hours = TimeEntry.visible.sum(:hours, :include => [:user], :conditions => cond.conditions).to_f
		
		result = TimeEntry.find_by_sql("select sum(v2." + spField + ") as " + spField + " from (" + selectStr + sqlStr + ") as v2")		
		@total_hours = result[0].hours
	end
	
	def findWkTEByCond(cond)
		@wktimes = Wktime.find(:all, :conditions => cond)
	end
	
	#Entries are now sorted alphanumerically according to their projectname (ASC) and according to their issue id (ASC)
	#mbraeu contribution:
	# Reworked SQL to modify key in "wktime_helper/getWeeklyView" for the custom_value.value
	# in order to distinguish between those values in the respective line (and not getting merged)
	# (1) Join of the tables time_entries with custom_values and projects + conditions
	# (2) Entries are now also sorted by their custom_value.value with the custom_field_id = 11 : being the values of the Custom_value Einsatzort (e.g: Home etc.)
	def findEntriesByCond(cond)
		 TimeEntry.joins('INNER JOIN custom_values ON time_entries.id = custom_values.customized_id').joins(:project)
							.where('custom_values.custom_field_id' => '11', 'custom_values.customized_type' => 'TimeEntry')
					  	.find(:all,
										:select => "custom_values.value, time_entries.*",
										:conditions => cond,
		      				  :order => 'projects.name, time_entries.issue_id, custom_values.value, created_on')
	end
	
	def setValueForSpField(teEntry,spValue,decimal_separator,entry)
		teEntry.hours = spValue.blank? ? nil : spValue.gsub(decimal_separator, '.').to_f
	end
	

	 def sendRejectionEmail
		raise_delivery_errors_old = ActionMailer::Base.raise_delivery_errors
		ActionMailer::Base.raise_delivery_errors = true
		begin
		unitLabel = getUnitLabel
		unit = params[:unit].to_s
		 @test = WkMailer.sendRejectionEmail(User.current,@user,@wktime,unitLabel,unit).deliver
		rescue Exception => e
		 # flash[:error] = l(:notice_email_error, e.message)
		end
		ActionMailer::Base.raise_delivery_errors = raise_delivery_errors_old
	
	end

	def getNewCustomField
		TimeEntry.new.custom_field_values
	end

	
	def getWkEntity
		Wktime.new 
	end
	
	def getTEEntry(id)	
		id.blank? ? TimeEntry.new : TimeEntry.find(id)
	end
	
	def deleteWkEntity(cond) 
	   Wktime.delete_all(cond)
	end	
	
	def delete(ids)
		TimeEntry.delete(ids)
	end
	
	def findTEEntries(ids)
		TimeEntry.find(ids)
	end
	
	def setTotal(wkEntity,total)
		wkEntity.hours = total
	end
	
	def setEntityLabel
		l(:label_wktime)
	end
	
	def setTEProjects(projects)
		projects
	end
	
	def createSpentOnHash(stDate)
		@hrPerDay = Hash.new
		for i in 0..6
			key = (stDate+i)
			@hrPerDay["#{key}"] = 0
		end
	end
	
	def validateMinMaxHr(stDate)
		errorMsg = nil
		minHr = minHour().to_i
		maxHr = maxHour().to_i
		if minHr > 0 || maxHr > 0
			nwdays = Setting.non_working_week_days
			phdays = getWdayForPublicHday(stDate)
			holidays = nwdays.concat(phdays)		
			for i in 0..6
				key = (stDate+i)
				if (!holidays.include?((key.cwday).to_s) || @hrPerDay["#{key}"] > 0)
					if minHr > 0 && !params[:wktime_submit].blank?
						if @hrPerDay["#{key}"] < minHr
							errorMsg = l(:text_wk_warning_min_hour, :value => "#{minHr}")
							break
						end
					end		
					if  maxHr > 0
						if @hrPerDay["#{key}"] > maxHr
							errorMsg = l(:text_wk_warning_max_hour, :value => "#{maxHr}")
							break
						end
					end
				end
			end
		end
		errorMsg
	end 
	
	def set_approvable_projects
		@approvable_projects ||= Project.find(:all, :order => 'name', 
			:conditions => Project.allowed_to_condition(User.current, :approve_time_entries))
	end
	
	def getTEName
		"time"
	end	
	
	def getSelectedProject(projList)
		selected_proj_id = params[:project_id]
		if !selected_proj_id.blank?
			sel_project = projList.select{ |proj| proj.id == selected_proj_id.to_i }	
			selected_project ||= sel_project[0] if !sel_project.blank?
		else
			selected_project ||= projList[0] if !projList.blank?
		end
	end
	
	def check_view_redirect
		# the user with view_time_entries permission will only be allowed to view list page
		unless checkViewPermission
			render_403
			return false
		end
	end
	
	def check_log_time_redirect
		set_user_projects
		# the user with log_time permission will only be allowed to enter new time/expense sheet
		if @currentUser_loggable_projects.blank?		
			render_403
			return false
		end
	end
	
	def formPaginationCondition
		rangeStr = ""
		if ActiveRecord::Base.connection.adapter_name == 'SQLServer'				
			status = params[:status]
			if !status.blank? && status != 'all'
				rangeStr = " AND (rownum > " + @offset.to_s  + " AND rownum <= " + (@offset  + @limit ).to_s + ")"
			else			
				rangeStr =" WHERE rownum > " + @offset.to_s  + " AND rownum <= " + (@offset  + @limit ).to_s
			end   
		else		
			rangeStr = 	" LIMIT " + @limit.to_s +	" OFFSET " + @offset.to_s
		end
		rangeStr
	end
end
