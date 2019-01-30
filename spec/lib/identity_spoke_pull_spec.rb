require 'rails_helper'

describe IdentitySpoke do
  context 'fetching new messages' do

    before(:all) do
      Sidekiq::Testing.inline!
    end

    after(:all) do
      Sidekiq::Testing.fake!
    end

    before(:each) do
      clean_external_database
      $redis.reset

      @subscription = FactoryBot.create(:sms_subscription)
      @time = Time.now - 120.seconds
      @spoke_organization = FactoryBot.create(:spoke_organization)
      @spoke_campaign = FactoryBot.create(:spoke_campaign, title: 'Test', organization: @spoke_organization)
      @spoke_user = FactoryBot.create(:spoke_user)
      @interaction_step1 = FactoryBot.create(:spoke_interaction_step, campaign: @spoke_campaign, question: 'voting_intention')
      @interaction_step2 = FactoryBot.create(:spoke_interaction_step, campaign: @spoke_campaign, question: 'favorite_party')
      3.times do |n|
        n += 1
        campaign_contact = FactoryBot.create(:spoke_campaign_contact, first_name: "Bob#{n}", cell: "+6142770040#{n}", campaign: @spoke_campaign)
        spoke_assignment = FactoryBot.create(:spoke_assignment, campaign_contacts: [campaign_contact], user: @spoke_user, campaign: @spoke_campaign)
        FactoryBot.create(:spoke_message_delivered, created_at: @time, id: n, assignment: spoke_assignment, user_number: @spoke_user.cell, contact_number: campaign_contact.cell, user_number: @spoke_user.cell)
        FactoryBot.create(:spoke_message_errored, created_at: @time, id: n+3, assignment: spoke_assignment, user_number: @spoke_user.cell, contact_number: campaign_contact.cell, user_number: @spoke_user.cell)
        FactoryBot.create(:spoke_response_delivered, created_at: @time, id: n+6, assignment: spoke_assignment, user_number: @spoke_user.cell, contact_number: campaign_contact.cell, user_number: @spoke_user.cell)
        FactoryBot.create(:spoke_question_response, value: 'yes', interaction_step: @interaction_step1, campaign_contact: campaign_contact)
        FactoryBot.create(:spoke_question_response, value: 'no', interaction_step: @interaction_step2, campaign_contact: campaign_contact)
        FactoryBot.create(:spoke_question_response, value: 'maybe', interaction_step: @interaction_step2, campaign_contact: campaign_contact)
      end
    end

    it "should skip and notify if campaign_contact phone can't be matched" do
      IdentitySpoke::Message.all.destroy_all

      campaign_contact = FactoryBot.create(:spoke_campaign_contact, cell: '+61481565899', campaign: @spoke_campaign)
      spoke_assignment = FactoryBot.create(:spoke_assignment, campaign_contacts: [campaign_contact], user: @spoke_user, campaign: @spoke_campaign)
      message = FactoryBot.create(:spoke_message_delivered, id: IdentitySpoke::Message.maximum(:id).to_i + 1, created_at: @time, assignment: spoke_assignment, send_status: 'DELIVERED', user_number: @spoke_user.cell, contact_number: '+61481565811')

      expect(Notify).to receive(:warning)
      IdentitySpoke.fetch_new_messages

      expect(Contact.count).to eq(0)
    end

    it 'should create new members if none exist' do
      IdentitySpoke.fetch_new_messages
      expect(Member.count).to eq(4)
    end

    it 'should create new members for campaign contacts' do
      IdentitySpoke.fetch_new_messages
      member = Member.find_by_phone('61427700401')
      expect(member).to have_attributes(first_name: 'Bob1')
      expect(member.contacts_received.count).to eq(1)
      expect(member.contacts_made.count).to eq(1)
    end

    it 'should create new members for user if none exist' do
      IdentitySpoke.fetch_new_messages
      member = Member.find_by_phone('61411222333')
      expect(member).to have_attributes(first_name: 'Super', last_name: 'Vollie')
      expect(member.contacts_received.count).to eq(3)
      expect(member.contacts_made.count).to eq(3)
    end    

    it 'should match existing members for campaign contacts and user' do
      IdentitySpoke::CampaignContact.all.each do |campaign_contact|
        Member.upsert_member(phones: [{ phone: campaign_contact.cell.sub(/^[+]*/,'') }], firstname: campaign_contact.first_name, lastname: campaign_contact.last_name)
      end
      user = IdentitySpoke::User.last
      Member.upsert_member(phones: [{ phone: user.cell.sub(/^[+]*/,'') }], firstname: user.first_name, lastname: user.last_name)

      IdentitySpoke.fetch_new_messages
      expect(Member.count).to eq(4)
    end

    it 'should create a contact campaign' do
      IdentitySpoke.fetch_new_messages
      expect(ContactCampaign.count).to eq(1)
      expect(ContactCampaign.first.contacts.count).to eq(6)
      expect(ContactCampaign.first).to have_attributes(name: @spoke_campaign.title, external_id: @spoke_campaign.id, system: 'spoke', contact_type: 'sms')
    end

    it 'should fetch the new outbound contacts and insert them' do
      IdentitySpoke.fetch_new_messages
      expect(Contact.where(notes: 'outbound').count).to eq(3)
    end

    it 'should fetch the new inbound contacts and insert them' do
      IdentitySpoke.fetch_new_messages
      expect(Contact.where(notes: 'outbound').count).to eq(3)
    end

    context('with force=true passed as parameter') do
      ContactResponse.all.destroy_all
      Contact.all.destroy_all
      before { IdentitySpoke::Message.update_all(created_at: '1960-01-01 00:00:00') }

      it 'should ignore the last_created_at and fetch the new contacts and insert them' do
        IdentitySpoke.fetch_new_messages(force: true)
        expect(Contact.count).to eq(6)
      end
    end

    it 'should record contactee and contactor details on contact' do
      IdentitySpoke.fetch_new_messages
      contact = Contact.find_by_external_id('1')
      contactee = Member.find_by_phone(IdentitySpoke::Message.first.contact_number.sub(/^[+]*/,''))
      contactor = Member.find_by_phone(@spoke_user.cell.sub(/^[+]*/,''))

      expect(contact.contactee_id).to eq(contactee.id)
      expect(contact.contactor_id).to eq(contactor.id)
    end

    it 'should record specific details on contact' do
      IdentitySpoke.fetch_new_messages
      expect(Contact.find_by_external_id('1')).to have_attributes(system: 'spoke', contact_type: 'sms', status: 'DELIVERED')
      expect(Contact.find_by_external_id('1').happened_at.utc.to_s).to eq(@time.utc.to_s)
    end

    it 'should create contact with a landline number set' do
      campaign_contact = FactoryBot.create(:spoke_campaign_contact, first_name: 'HomeBoy', cell: '+61727700400', campaign: @spoke_campaign)
      spoke_assignment = FactoryBot.create(:spoke_assignment, campaign_contacts: [campaign_contact], user: @spoke_user, campaign: @spoke_campaign)
      message = FactoryBot.create(:spoke_message_delivered, created_at: @time, id: '123', assignment: spoke_assignment, send_status: 'DELIVERED', contact_number: campaign_contact.cell, user_number: @spoke_user.cell)
      IdentitySpoke.fetch_new_messages
      expect(Contact.last).to have_attributes(external_id: '123', status: 'DELIVERED')
      expect(Contact.last.happened_at.utc.to_s).to eq(@time.utc.to_s)
      expect(Contact.last.contactee.phone).to eq('61727700400')
    end

    it 'should create contact if there is no name st' do
      campaign_contact = FactoryBot.create(:spoke_campaign_contact, cell: '+61427700409', campaign: @spoke_campaign)
      spoke_assignment = FactoryBot.create(:spoke_assignment, campaign_contacts: [campaign_contact], user: @spoke_user, campaign: @spoke_campaign)
      message = FactoryBot.create(:spoke_message_delivered, id: IdentitySpoke::Message.maximum(:id).to_i + 1, created_at: @time, assignment: spoke_assignment, send_status: 'DELIVERED', user_number: @spoke_user.cell, contact_number: campaign_contact.cell)
      IdentitySpoke.fetch_new_messages
      expect(Contact.last.contactee.phone).to eq('61427700409')
    end

    it 'should upsert messages' do
      member = FactoryBot.create(:member, first_name: 'Janis')
      member.update_phone_number('61427700401')
      FactoryBot.create(:contact, contactee: member, external_id: '2')
      IdentitySpoke.fetch_new_messages
      expect(Contact.count).to eq(6)
      expect(member.contacts_received.count).to eq(1)
    end

    it 'should be idempotent' do
      IdentitySpoke.fetch_new_messages
      contact_hash = Contact.all.select('contactee_id, contactor_id, duration, system, contact_campaign_id').as_json
      cr_count = ContactResponse.all.count
      IdentitySpoke.fetch_new_messages
      expect(Contact.all.select('contactee_id, contactor_id, duration, system, contact_campaign_id').as_json).to eq(contact_hash)
      expect(ContactResponse.all.count).to eq(cr_count)
    end

    it 'should correctly save Survey Results' do
      IdentitySpoke.fetch_new_messages
      contact_response = ContactCampaign.last.contact_response_keys.find_by(key: 'voting_intention').contact_responses.first
      expect(contact_response.value).to eq('yes')
      contact_response = ContactCampaign.last.contact_response_keys.find_by(key: 'favorite_party').contact_responses.first
      expect(contact_response.value).to eq('no')
      expect(Contact.first.contact_responses.count).to eq(3)
    end

    it 'should correctly not duplicate Survey Results' do
      IdentitySpoke.fetch_new_messages
      spoke_assignment = IdentitySpoke::Assignment.first
      campaign_contact = IdentitySpoke::CampaignContact.first
      FactoryBot.create(:spoke_message_delivered, created_at: @time, id: 123456, assignment: spoke_assignment, user_number: @spoke_user.cell, contact_number: campaign_contact.cell, user_number: @spoke_user.cell)
      IdentitySpoke.fetch_new_messages
      contact_response = ContactCampaign.last.contact_response_keys.find_by(key: 'voting_intention').contact_responses.first
      expect(contact_response.value).to eq('yes')
      contact_response = ContactCampaign.last.contact_response_keys.find_by(key: 'favorite_party').contact_responses.first
      expect(contact_response.value).to eq('no')
      expect(Contact.first.contact_responses.count).to eq(3)
    end

    it 'should update the last_created_at' do
      old_created_at = $redis.with { |r| r.get 'spoke:messages:last_created_at' }
      sleep 2
      campaign_contact = FactoryBot.create(:spoke_campaign_contact, first_name: 'BobNo', cell: '+61427700408', campaign: @spoke_campaign)
      spoke_assignment = FactoryBot.create(:spoke_assignment, campaign_contacts: [campaign_contact], user: @spoke_user, campaign: @spoke_campaign)
      message = FactoryBot.create(:spoke_message_delivered, id: IdentitySpoke::Message.maximum(:id).to_i + 1, created_at: @time, assignment: spoke_assignment, send_status: 'DELIVERED', user_number: @spoke_user.cell, contact_number: campaign_contact.cell)
      IdentitySpoke.fetch_new_messages
      new_created_at = $redis.with { |r| r.get 'spoke:messages:last_created_at' }
      expect(new_created_at).not_to eq(old_created_at)
    end
  end

  context 'fetching new opt outs' do

    before(:all) do
      Sidekiq::Testing.inline!
    end

    after(:all) do
      Sidekiq::Testing.fake!
    end

    before(:each) do
      clean_external_database
      $redis.reset
      @subscription = FactoryBot.create(:sms_subscription)
      Settings.stub_chain(:spoke, :opt_out_subscription_id) { @subscription.id }
      @time = Time.now - 120.seconds
      @spoke_organization = FactoryBot.create(:spoke_organization)
      @spoke_campaign = FactoryBot.create(:spoke_campaign, title: 'Test', organization: @spoke_organization)
      @spoke_user = FactoryBot.create(:spoke_user)
    end

    it 'should opt out people that need it' do
      member = FactoryBot.create(:member, title: 'BobNo')
      member.update_phone_number('61427700409')
      member.subscribe_to(@subscription)
      expect(member.is_subscribed_to?(@subscription)).to eq(true)
      campaign_contact = FactoryBot.create(:spoke_campaign_contact, first_name: 'BobNo', cell: '+61427700409', campaign: @spoke_campaign)
      spoke_assignment = FactoryBot.create(:spoke_assignment, campaign_contacts: [campaign_contact], user: @spoke_user, campaign: @spoke_campaign)
      spoke_opt_out = FactoryBot.create(:spoke_opt_out, cell: campaign_contact.cell, organization: @spoke_organization, assignment: spoke_assignment)
      message = FactoryBot.create(:spoke_message_delivered, id: IdentitySpoke::Message.maximum(:id).to_i + 1, created_at: @time, assignment: spoke_assignment, send_status: 'DELIVERED', contact_number: campaign_contact.cell, user_number: @spoke_user.cell)
      IdentitySpoke.fetch_new_opt_outs
      member.reload
      expect(member.is_subscribed_to?(@subscription)).to eq(false)
    end
  end
end
