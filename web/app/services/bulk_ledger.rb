# frozen_string_literal: true

class BulkLedger
  def self.receive(material:, attributes:, movement_attributes:, actor:)
    require_tenant!(material)
    lot = BulkLot.new(attributes.slice(:code, :note, :receipt_token).merge(bulk_material: material, tenant_id: Current.tenant_id))
    lot.receipt_checked = true
    movement = build_movement(lot, movement_attributes.merge(kind: 'receipt', request_token: lot.receipt_token), actor)
    return invalid_lot(lot, movement) unless lot.valid? && movement.valid?

    existing = BulkLot.find_by(receipt_token: lot.receipt_token)
    return receipt_replay(existing, lot, movement) if existing

    BulkLot.transaction do
      # Insert is the first SQL statement in this transaction, avoiding SQLite
      # read-to-write upgrades when two receipt forms are submitted together.
      lot.save!(validate: false)
      movement.bulk_lot = lot
      movement.save!
      BulkLot.where(id: lot.id).update_all(balance_mg: movement.delta_mg)
    end
    lot.reload
  rescue ActiveRecord::RecordNotUnique
    existing = BulkLot.find_by(receipt_token: lot.receipt_token)
    return receipt_replay(existing, lot, movement) if existing

    if BulkMovement.exists?(request_token: lot.receipt_token)
      lot.errors.add(:base, 'This receipt request was already used. Reload the form to make a different receipt.')
    else
      lot.errors.add(:code, 'already exists for this material. Open that lot to record another receipt.')
    end
    lot
  end

  def self.record(lot:, attributes:, actor:)
    require_tenant!(lot)
    movement = build_movement(lot, attributes, actor)
    lot.serialize_movement do
      existing = BulkMovement.find_by(request_token: movement.request_token)
      if existing
        movement = movement_replay(existing, movement)
      elsif movement.valid?
        remaining = lot.balance_mg + movement.delta_mg
        if remaining.negative?
          movement.errors.add(:base, "Only #{lot.balance_mg} mg remain in this lot; movement would make its balance negative.")
        elsif remaining > BulkMass::MAX_MG
          movement.errors.add(:base, 'The resulting lot balance exceeds the supported range.')
        else
          movement.save!
          BulkLot.where(id: lot.id).update_all(balance_mg: remaining)
          lot.reload
        end
      end
    end
    movement
  rescue ActiveRecord::RecordNotUnique
    movement_replay(BulkMovement.find_by!(request_token: movement.request_token), movement)
  end

  def self.build_movement(lot, attributes, actor)
    movement = BulkMovement.new(attributes.slice(:kind, :reference, :request_token).merge(
      bulk_lot: lot, tenant_id: Current.tenant_id, created_by: actor, input_unit: attributes[:unit],
      input_quantity: attributes[:quantity].to_s, balance_checked: true
    ))
    begin
      milligrams, canonical = BulkMass.convert(attributes[:quantity], attributes[:unit], signed: attributes[:kind] == 'adjustment')
      movement.input_quantity = canonical
      movement.delta_mg = attributes[:kind] == 'consume' ? -milligrams : milligrams
    rescue ArgumentError => e
      movement.conversion_error = e.message
    end
    movement
  end

  def self.require_tenant!(record)
    raise ActiveRecord::RecordNotFound unless Current.tenant_id.present? && record.tenant_id == Current.tenant_id
  end

  def self.invalid_lot(lot, movement)
    movement.errors.full_messages.each { |message| lot.errors.add(:base, message) }
    lot
  end

  def self.receipt_replay(existing, requested, movement)
    original = existing.bulk_movements.order(:id).first
    same_lot = %w[bulk_material_id code note].all? { |field| existing[field] == requested[field] }
    same_movement = %w[kind delta_mg input_unit input_quantity reference created_by].all? { |field| original&.[](field) == movement[field] }
    return existing if same_lot && same_movement

    requested.errors.add(:base, 'This receipt request was already used. Reload the form to make a different receipt.')
    requested
  end

  def self.movement_replay(existing, requested)
    fields = %w[bulk_lot_id kind delta_mg input_unit input_quantity reference created_by]
    return existing if fields.all? { |field| existing[field] == requested[field] }

    requested.errors.add(:base, 'This movement request was already used. Reload the lot to record a different movement.')
    requested
  end

  private_class_method :build_movement, :require_tenant!, :invalid_lot, :receipt_replay, :movement_replay
end
