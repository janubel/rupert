# frozen_string_literal: true

# A live, printable picture of sales sources, products, cash and vendors, with
# an option to retain a dated copy as evidence.
class BusinessSnapshotsController < AuthenticatedController
  before_action -> { authorize(:module, :finance_read?) }
  before_action -> { authorize(:module, :reports_write?) }, only: :create
  before_action { response.headers['Cache-Control'] = 'private, no-store' }

  def show
    @snapshot = BusinessSnapshot.new
    @data = @snapshot.to_h
    ActivityLogger.log('business_snapshot_viewed')
  end

  def create
    snapshot = BusinessSnapshot.new
    day = Date.current.iso8601
    doc = ReconciliationEvidence.retain!(bytes: JSON.pretty_generate(snapshot.to_h), filename: "business-snapshot-#{day}.json", source: 'rupert',
      kind: 'period_archive', from: day, to: day, metadata: { 'note' => 'Business snapshot saved by a person' }, actor: Current.user)
    ActivityLogger.log('business_snapshot_saved', subject: doc, details: "#{day}; sha256 #{doc.sha256.first(12)}")
    redirect_to business_snapshot_path, notice: "Dated copy saved as evidence ##{doc.id}. It cannot be edited."
  rescue ReconciliationEvidence::Error => e
    redirect_to business_snapshot_path, alert: e.message
  end
end
