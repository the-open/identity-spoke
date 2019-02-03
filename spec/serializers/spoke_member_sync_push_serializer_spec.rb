describe IdentitySpoke::SpokeMemberSyncPushSerializer do
  context 'serialize' do
    before(:each) do
      clean_external_database
      Settings.stub_chain(:spoke) { {} }
      @sync_id = 1
      @spoke_organization = FactoryBot.create(:spoke_organization)
      @spoke_campaign = FactoryBot.create(:spoke_campaign, organization: @spoke_organization)
      @external_system_params = JSON.generate({'campaign_id' => @spoke_campaign.id})
      @member = FactoryBot.create(:member_with_mobile_and_custom_fields)
      list = FactoryBot.create(:list)
      FactoryBot.create(:list_member, list: list, member: @member)
      FactoryBot.create(:member_with_mobile)
      FactoryBot.create(:member)
      @batch_members = Member.all.with_mobile.in_batches.first
    end

    it 'returns valid object' do
      rows = ActiveModel::Serializer::CollectionSerializer.new(
        @batch_members,
        serializer: IdentitySpoke::SpokeMemberSyncPushSerializer,
        campaign_id: @spoke_campaign.id
      ).as_json
      expect(rows.count).to eq(2)
      expect(rows[0][:external_id]).to eq(ListMember.first.member_id)
      expect(rows[0][:cell]).to eq("+#{@member.mobile}")
      expect(rows[0][:campaign_id]).to eq(@spoke_campaign.id)
      expect(rows[0][:custom_fields]).to eq("{\"secret\":\"me_likes\"}")
    end

    it "only returns the most recently updated phone number" do
      @member.update_phone_number('61427700500', 'mobile')
      @member.update_phone_number('61427700600', 'mobile')
      @member.update_phone_number('61427700500', 'mobile')
      @batch_members = Member.all.with_phone_numbers.in_batches.first
      rows = ActiveModel::Serializer::CollectionSerializer.new(
        @batch_members,
        serializer: IdentitySpoke::SpokeMemberSyncPushSerializer,
        campaign_id: @spoke_campaign.id
      ).as_json
      expect(rows.first[:cell]).to eq('+61427700500')
    end
  end
end
