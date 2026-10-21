# frozen_string_literal: true

module Uploads
  # What an importer thinks a file is. `confidence` is 0.0 to 1.0 and `reason`
  # says in plain words which evidence it used, so a person can disagree.
  Detection = Struct.new(:type, :label, :confidence, :reason, :importer, :source, keyword_init: true) do
    def percent = (confidence.to_f * 100).round

    def to_h
      { 'type' => type, 'label' => label, 'confidence' => percent, 'reason' => reason, 'importer' => importer, 'source' => source }
    end
  end

  # What a dry run or an import reports. `summary` is shown to the operator:
  # 'headline' (one sentence), 'counts' (label => number) and 'warnings'.
  Outcome = Struct.new(:ok, :summary, :message, :path, keyword_init: true)
end
