class SubmittedContentController < ApplicationController
  require 'mimemagic'
  require 'mimemagic/overlay'

  include AuthorizationHelper

  def action_allowed?
    case params[:action]
    when 'edit'
      current_user_has_student_privileges? &&
        are_needed_authorizations_present?(params[:id], 'reader', 'reviewer')
    when 'submit_file', 'submit_hyperlink'
      current_user_has_student_privileges? &&
        one_team_can_submit_work?
    else
      current_user_has_student_privileges?
    end
  end

  def controller_locale
    locale_for_student
  end

  # The view have already tested that @assignment.submission_allowed(topic_id) is true,
  # so @can_submit should be true
  def edit
    @participant = AssignmentParticipant.find(params[:id])
    return unless current_user_id?(@participant.user_id)

    @assignment = @participant.assignment
    # ACS We have to check if this participant has team or not
    SignUpSheet.signup_team(@assignment.id, @participant.user_id, nil) if @participant.team.nil?
    # @can_submit is the flag indicating if the user can submit or not in current stage
    @can_submit = !params.key?(:view)
    @stage = @assignment.current_stage(SignedUpTeam.topic_id(@participant.parent_id, @participant.user_id))
  end

  # view is called when @assignment.submission_allowed(topic_id) is false
  # so @can_submit should be false
  def prevent_submission
    @participant = AssignmentParticipant.find(params[:id])
    return unless current_user_id?(@participant.user_id)

    @assignment = @participant.assignment
    # @can_submit is the flag indicating if the user can submit or not in current stage
    @can_submit = false
    @stage = @assignment.current_stage(SignedUpTeam.topic_id(@participant.parent_id, @participant.user_id))
    redirect_to action: 'edit', id: params[:id], view: true
  end

  def submit_hyperlink
    @participant = AssignmentParticipant.find(params[:id])
    return unless current_user_id?(@participant.user_id)

    team = @participant.team
    team_hyperlinks = team.hyperlinks
    if team_hyperlinks.include?(params['submission'])
      ExpertizaLogger.error LoggerMessage.new(controller_name, @participant.name, 'You or your teammate(s) have already submitted the same hyperlink.', request)
      flash[:error] = 'You or your teammate(s) have already submitted the same hyperlink.'
    else
      begin
        team.submit_hyperlink(params['submission'])
        SubmissionRecord.create(team_id: team.id,
                                content: params['submission'],
                                user: @participant.name,
                                assignment_id: @participant.assignment.id,
                                operation: 'Submit Hyperlink')
      rescue StandardError
        ExpertizaLogger.error LoggerMessage.new(controller_name, @participant.name, "The URL or URI is invalid. Reason: #{$ERROR_INFO}", request)
        flash[:error] = "The URL or URI is invalid. Reason: #{$ERROR_INFO}"
      end
      @participant.mail_assigned_reviewers
      ExpertizaLogger.info LoggerMessage.new(controller_name, @participant.name, 'The link has been successfully submitted.', request)
      undo_link('The link has been successfully submitted.')
    end
    redirect_to action: 'edit', id: @participant.id
  end

  def remove_hyperlink
    @participant = AssignmentParticipant.find(params[:hyperlinks][:participant_id])
    return unless current_user_id?(@participant.user_id)

    team = @participant.team
    hyperlink_to_delete = team.hyperlinks[params['chk_links'].to_i]
    team.remove_hyperlink(hyperlink_to_delete)
    ExpertizaLogger.info LoggerMessage.new(controller_name, @participant.name, 'The link has been successfully removed.', request)
    undo_link('The link has been successfully removed.')
    # determine if the user should be redirected to "edit" or  "view" based on the current deadline right
    topic_id = SignedUpTeam.topic_id(@participant.parent_id, @participant.user_id)
    assignment = Assignment.find(@participant.parent_id)
    SubmissionRecord.create(team_id: team.id,
                            content: hyperlink_to_delete,
                            user: @participant.name,
                            assignment_id: assignment.id,
                            operation: 'Remove Hyperlink')
    action = (assignment.submission_allowed(topic_id) ? 'edit' : 'view')
    redirect_to action: action, id: @participant.id
  end

  def submit_file
    participant = AssignmentParticipant.find(params[:id])
    unless current_user_id?(participant.user_id)
      flash[:error] = "Authentication Error"
      redirect_to action: 'edit', id: participant.id
      return
    end

    file = params[:uploaded_file]
    file_size_limit = 5

    # check file size
    unless check_content_size(file, file_size_limit)
      flash[:error] = "File size must smaller than #{file_size_limit}MB"
      redirect_to action: 'edit', id: participant.id
      return
    end

    file_content = file.read

    # check file type
    unless check_content_type_integrity(file_content)
      flash[:error] = 'File type error'
      redirect_to action: 'edit', id: participant.id
      return
    end
    full_filename = get_file_upload(participant, file, file_content)
    assignment = Assignment.find(participant.parent_id)
    team = participant.team
    SubmissionRecord.create(team_id: team.id,
                            content: full_filename,
                            user: participant.name,
                            assignment_id: assignment.id,
                            operation: "Submit File")
    ExpertizaLogger.info LoggerMessage.new(controller_name, participant.name, 'The file has been submitted.', request)
    notify_reviewers(participant)
  end

  def get_file_upload(participant, file, file_content)
    participant.team.set_student_directory_num
    @current_folder = DisplayOption.new
    @current_folder.name = '/'
    @current_folder.name = FileHelper.sanitize_folder(params[:current_folder][:name]) if params[:current_folder]
    curr_directory = if params[:origin] == 'review'
                       participant.review_file_path(params[:response_map_id]).to_s + @current_folder.name
                     else
                       participant.team.path.to_s + @current_folder.name
                     end
    FileUtils.mkdir_p(curr_directory) unless File.exist? curr_directory
    safe_filename = file.original_filename.tr('\\', '/')
    safe_filename = FileHelper.sanitize_filename(safe_filename) # new code to sanitize file path before upload*
    full_filename = curr_directory + File.split(safe_filename).last.tr(' ', '_') # safe_filename #curr_directory +
    File.open(full_filename, 'wb') { |f| f.write(file_content) }
    if params['unzip']
      SubmittedContentHelper.unzip_file(full_filename, curr_directory, true) if file_type(safe_filename) == 'zip'
    end
    return full_filename
  end

  def notify_reviewers(participant)
    participant.mail_assigned_reviewers

    if params[:origin] == 'review'
      redirect_to :back
    else
      redirect_to action: 'edit', id: participant.id
    end
  end

  # def perform_folder_action
  #   @participant = AssignmentParticipant.find(params[:id])
  #   return unless current_user_id?(@participant.user_id)

  #   @current_folder = DisplayOption.new
  #   @current_folder.name = '/'
  #   @current_folder.name = FileHelper.sanitize_folder(params[:current_folder][:name]) if params[:current_folder]
  #   if params[:faction][:delete]
  #     delete_selected_files
  #   elsif params[:faction][:rename]
  #     rename_selected_file
  #   elsif params[:faction][:move]
  #     move_selected_file
  #   elsif params[:faction][:copy]
  #     copy_selected_file
  #   elsif params[:faction][:create]
  #     create_new_folder
  #   end
  #   redirect_to action: 'edit', id: @participant.id
  # end

  # def download
  #   folder_name = params['current_folder']['name']
  #   file_name = params['download']
  #   raise 'Folder_name is nil.' if folder_name.nil?
  #   raise 'File_name is nil.' if file_name.nil?
  #   raise 'Cannot send a whole folder.' if File.directory?(folder_name + '/' + file_name)
  #   raise 'File does not exist.' unless File.exist?(folder_name + '/' + file_name)

  #   send_file(folder_name + '/' + file_name, disposition: 'inline')
  # rescue StandardError => e
  #   flash[:error] = e.message
  # end

  private

  # Verify the integrity of uploaded files.
  # @param file_content [Object] the content of uploaded file
  # @return [Boolean] the result of verification
  def check_content_type_integrity(file_content)
    limited_types = %w[application/pdf image/png image/jpeg application/zip application/x-tar application/x-7z-compressed application/vnd.oasis.opendocument.text application/vnd.openxmlformats-officedocument.wordprocessingml.document]
    mime = MimeMagic.by_magic(file_content)
    limited_types.include? mime.to_s
  end

  # Verify the size of uploaded file is under specific value.
  # @param file [Object] uploaded file
  # @param size [Integer] maximum size(MB)
  # @return [Boolean] the result of verification
  def check_content_size(file, size)
    file.size <= size * 1024 * 1024
  end

  def file_type(file_name)
    base = File.basename(file_name)
    base.split('.')[base.split('.').size - 1] if base.split('.').size > 1
  end

  # if one team do not hold a topic (still in waitlist), they cannot submit their work.
  def one_team_can_submit_work?
    @participant = if params[:id].nil?
                     AssignmentParticipant.find(params[:hyperlinks][:participant_id])
                   else
                     AssignmentParticipant.find(params[:id])
                   end
    @topics = SignUpTopic.where(assignment_id: @participant.parent_id)
    # check one assignment has topics or not
    (!@topics.empty? && !SignedUpTeam.topic_id(@participant.parent_id, @participant.user_id).nil?) || @topics.empty?
  end
end
