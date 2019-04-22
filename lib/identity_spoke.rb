require "identity_spoke/engine"

module IdentitySpoke
  SYSTEM_NAME = 'spoke'
  PULL_BATCH_AMOUNT = 1000
  PUSH_BATCH_AMOUNT = 1000
  SYNCING = 'campaign'
  CONTACT_TYPE = 'sms'
  PULL_JOBS = [[:fetch_new_messages, 5.minutes], [:fetch_new_opt_outs, 30.minutes], [:fetch_active_campaigns, 10.minutes]]

  def self.push(sync_id, members, external_system_params)
    begin
      external_campaign_id = JSON.parse(external_system_params)['campaign_id'].to_i
      external_campaign_name = Campaign.find(external_campaign_id).title

      yield members.with_mobile, external_campaign_name
    rescue => e
      raise e
    end
  end

  def self.push_in_batches(sync_id, members, external_system_params)
    begin
      external_campaign_id = JSON.parse(external_system_params)['campaign_id'].to_i
      members.in_batches(of: get_push_batch_amount).each_with_index do |batch_members, batch_index|
        rows = ActiveModel::Serializer::CollectionSerializer.new(
          batch_members,
          serializer: SpokeMemberSyncPushSerializer,
          campaign_id: external_campaign_id
        ).as_json
        write_result_count = CampaignContact.add_members(rows)

        yield batch_index, write_result_count
      end
    rescue => e
      raise e
    end
  end

  def self.description(sync_type, external_system_params, contact_campaign_name)
    external_system_params_hash = JSON.parse(external_system_params)
    if sync_type === 'push'
      "#{SYSTEM_NAME.titleize} - #{SYNCING.titleize}: #{contact_campaign_name} ##{external_system_params_hash['campaign_id']} (#{CONTACT_TYPE})"
    else
      "#{SYSTEM_NAME.titleize}: #{external_system_params_hash['pull_job']}"
    end
  end

  def self.base_campaign_url(campaign_id)
    Settings.spoke.base_campaign_url ? sprintf(Settings.spoke.base_campaign_url, campaign_id.to_s) : nil
  end

  def self.worker_currenly_running?(method_name)
    workers = Sidekiq::Workers.new
    workers.each do |_process_id, _thread_id, work|
      matched_process = work["payload"]["args"] = [SYSTEM_NAME, method_name]
      if matched_process
        puts ">>> #{SYSTEM_NAME.titleize} #{method_name} skipping as worker already running ..."
        return true
      end
    end
    puts ">>> #{SYSTEM_NAME.titleize} #{method_name} running ..."
    return false
  end

  def self.get_pull_batch_amount
    Settings.spoke.pull_batch_amount || PULL_BATCH_AMOUNT
  end

  def self.get_push_batch_amount
    Settings.spoke.push_batch_amount || PUSH_BATCH_AMOUNT
  end

  def self.get_pull_jobs
    defined?(PULL_JOBS) && PULL_JOBS.is_a?(Array) ? PULL_JOBS : []
  end

  def self.pull(sync_id, external_system_params)
    begin
      pull_job = JSON.parse(external_system_params)['pull_job'].to_s
      self.send(pull_job, sync_id) do |records_for_import_count, records_for_import, records_for_import_scope, pull_deferred|
        yield records_for_import_count, records_for_import, records_for_import_scope, pull_deferred
      end
    rescue => e
      raise e
    end
  end

  def self.fetch_new_messages(sync_id, force: false)
    ## Do not run method if another worker is currently processing this method
    yield 0, {}, {}, true if self.worker_currenly_running?(__method__.to_s)

    last_created_at = Time.parse($redis.with { |r| r.get 'spoke:messages:last_created_at' } || '2019-01-01 00:00:00')
    updated_messages = Message.updated_messages(force ? DateTime.new() : last_created_at)

    iteration_method = force ? :find_each : :each
    updated_messages.send(iteration_method) do |message|
      self.delay(retry: false, queue: 'low').handle_new_message(sync_id, message.id)
    end

    unless updated_messages.empty?
      $redis.with { |r| r.set 'spoke:messages:last_created_at', updated_messages.last.created_at }
    end

    yield updated_messages.size, updated_messages.pluck(:id), { scope: 'spoke:messages:last_created_at', from: last_created_at, to: updated_messages.empty? ? nil : updated_messages.last.created_at }, false
  end

  def self.handle_new_message(sync_id, message_id)
    audit_data = {sync_id: sync_id}
    ## Get the message
    message = IdentitySpoke::Message.find(message_id)

    ## Find who is the campaign contact for the message
    unless campaign_contact = IdentitySpoke::CampaignContact.find_by(campaign_id: message.assignment.campaign.id, cell: message.contact_number)
      Notify.warning "Spoke: CampaignContact Find Failed", "campaign_id: #{message.assignment.campaign.id}, cell: #{message.contact_number}"
      return
    end

    ## Create Members for both the user and campaign contact
    campaign_contact_member = Member.upsert_member(
      {
        phones: [{ phone: campaign_contact.cell.sub(/^[+]*/,'') }],
        firstname: campaign_contact.first_name,
        lastname: campaign_contact.last_name,
        member_id: campaign_contact.external_id
      },
      "#{SYSTEM_NAME}:#{__method__.to_s}",
      audit_data,
      false,
      true
    )
    user_member = Member.upsert_member(
      {
        phones: [{ phone: message.user.cell.sub(/^[+]*/,'') }],
        firstname: message.user.first_name,
        lastname: message.user.last_name
      },
      "#{SYSTEM_NAME}:#{__method__.to_s}",
      audit_data,
      false,
      false
    )

    ## Assign the contactor and contactee according to if the message was from the campaign contact
    contactor = message.is_from_contact ? campaign_contact_member: user_member
    contactee = message.is_from_contact ? user_member : campaign_contact_member

    ## Find or create the contact campaign
    contact_campaign = ContactCampaign.find_or_initialize_by(external_id: message.assignment.campaign.id, system: SYSTEM_NAME)
    contact_campaign.audit_data
    contact_campaign.update_attributes!(name: message.assignment.campaign.title, contact_type: CONTACT_TYPE)

    ## Find or create the contact
    contact = Contact.find_or_initialize_by(external_id: message.id, system: SYSTEM_NAME)
    contact.audit_data = audit_data
    contact.update_attributes!(contactee: contactee,
                              contactor: contactor,
                              contact_campaign: contact_campaign,
                              contact_type: CONTACT_TYPE,
                              happened_at: message.created_at,
                              status: message.send_status,
                              notes: message.is_from_contact ? 'inbound' : 'outbound')
    contact.reload

    ## Loop over all of the campaign contacts question responses if message is not from contact
    return if message.is_from_contact
    campaign_contact.question_responses.each do |qr|
      ### Find or create the contact response key
      contact_response_key = ContactResponseKey.find_or_initialize_by(key: qr.interaction_step.question, contact_campaign: contact_campaign)
      contact_response_key.audit_data = audit_data
      contact_response_key.save! if contact_response_key.new_record?

      ## Create a contact response against the contact if no existing contact response exists for the contactee
      matched_contact_responses = contactee.contact_responses.where(value: qr.value, contact_response_key: contact_response_key)
      if matched_contact_responses.empty?
        contact_response = ContactResponse.find_or_initialize_by(contact: contact, value: qr.value, contact_response_key: contact_response_key)
        contact_response.audit_data = audit_data
        contact_response.save! if contact_response.new_record?
      end
    end
  end

  def self.fetch_new_opt_outs(sync_id, force: false)
    ## Do not run method if another worker is currently processing this method
    yield 0, {}, {}, true if self.worker_currenly_running?(__method__.to_s)

    if Settings.spoke.subscription_id
      last_created_at = Time.parse($redis.with { |r| r.get 'spoke:opt_outs:last_created_at' } || '1970-01-01 00:00:00')
      updated_opt_outs = IdentitySpoke::OptOut.updated_opt_outs(force ? DateTime.new() : last_created_at)

      iteration_method = force ? :find_each : :each
      updated_opt_outs.send(iteration_method) do |opt_out|
        self.delay(retry: false, queue: 'low').handle_new_opt_out(sync_id, opt_out.id)
      end

      unless updated_opt_outs.empty?
        $redis.with { |r| r.set 'spoke:opt_outs:last_created_at', updated_opt_outs.last.created_at }
      end
      
      yield updated_opt_outs.size, updated_opt_outs.pluck(:id), { scope: 'spoke:opt_outs:last_created_at', from: last_created_at, to: updated_opt_outs.empty? ? nil : updated_opt_outs.last.created_at }, false
    end
  end

  def self.handle_new_opt_out(sync_id, opt_out_id)
    audit_data = {sync_id: sync_id}
    opt_out = IdentitySpoke::OptOut.find(opt_out_id)
    campaign_contact = IdentitySpoke::CampaignContact.where(cell: opt_out.cell).last
    if campaign_contact
      contactee = Member.upsert_member(
        {
          phones: [{ phone: campaign_contact.cell.sub(/^[+]*/,'') }],
          firstname: campaign_contact.first_name,
          lastname: campaign_contact.last_name,
          member_id: campaign_contact.external_id
        },
        "#{SYSTEM_NAME}:#{__method__.to_s}",
        audit_data,
        false,
        true
      )
      subscription = Subscription.find(Settings.spoke.subscription_id)
      contactee.unsubscribe_from(subscription, 'spoke:opt_out', DateTime.now, nil, audit_data) if contactee
    end
  end

  def self.fetch_active_campaigns(sync_id, force: false)
    ## Do not run method if another worker is currently processing this method
    yield 0, {}, {}, true if self.worker_currenly_running?(__method__.to_s)

    active_campaigns = IdentitySpoke::Campaign.active

    iteration_method = force ? :find_each : :each

    active_campaigns.send(iteration_method) do |campaign|
      self.delay(retry: false, queue: 'low').handle_campaign(sync_id, campaign.id)
    end

    yield active_campaigns.size, active_campaigns.pluck(:id), { }, false
  end

  def self.handle_campaign(sync_id, campaign_id)
    audit_data = {sync_id: sync_id}
    campaign = IdentitySpoke::Campaign.find(campaign_id)

    contact_campaign = ContactCampaign.find_or_initialize_by(external_id: campaign.id, system: SYSTEM_NAME)
    contact_campaign.audit_data = audit_data
    contact_campaign.update!(name: campaign.title, contact_type: CONTACT_TYPE)

    campaign.interaction_steps.each do |interaction_step|
      contact_response_key = ContactResponseKey.find_or_initialize_by(key: interaction_step.question, contact_campaign: contact_campaign)
      contact_response_key.audit_data = audit_data
      contact_response_key.save! if contact_response_key.new_record?
    end
  end
end
