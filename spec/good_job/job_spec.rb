require 'rails_helper'

RSpec.describe GoodJob::Job do
  let(:job) { described_class.create! }

  before do
    stub_const "RUN_JOBS", Concurrent::Array.new
    stub_const 'ExpectedError', Class.new(StandardError)
    stub_const 'ExampleJob', (Class.new(ApplicationJob) do
      self.queue_name = 'test'
      self.priority = 50

      def perform(result_value = nil, raise_error: false)
        RUN_JOBS << provider_job_id
        raise ExpectedError, "Raised expected error" if raise_error

        result_value
      end
    end)
  end

  it_behaves_like 'promotable'

  describe '.enqueue' do
    let(:active_job) { ExampleJob.new }

    it 'creates a new GoodJob record' do
      good_job = nil

      expect do
        good_job = described_class.enqueue(active_job)
      end.to change(described_class, :count).by(1)

      expect(good_job).to have_attributes(
        serialized_params: a_kind_of(Hash),
        queue_name: 'test',
        priority: 50,
        scheduled_at: within(1.second).of(Time.current)
      )
    end

    it 'is schedulable' do
      good_job = described_class.enqueue(active_job, scheduled_at: 1.day.from_now)
      expect(good_job).to have_attributes(
        scheduled_at: within(1.second).of(1.day.from_now)
      )
    end

    it 'can be created with an advisory lock' do
      unlocked_good_job = described_class.enqueue(active_job)
      expect(unlocked_good_job.advisory_locked?).to eq false

      locked_good_job = described_class.enqueue(active_job, create_with_advisory_lock: true)
      expect(locked_good_job.advisory_locked?).to eq true
    end
  end

  describe '.perform_with_advisory_lock' do
    let(:active_job) { ExampleJob.new('a string') }
    let!(:good_job) { described_class.enqueue(active_job) }

    it 'performs one job' do
      good_job_2 = described_class.create!(serialized_params: {})

      described_class.all.perform_with_advisory_lock

      expect { good_job.reload }.to raise_error ActiveRecord::RecordNotFound
      expect { good_job_2.reload }.not_to raise_error
    end

    it 'returns the good_job, result, and error object if there is a result; nil if not' do
      worked_good_job, worked_result, worked_error = described_class.all.perform_with_advisory_lock

      expect(worked_good_job).to eq good_job
      expect(worked_result).to eq 'a string'
      expect(worked_error).to eq nil

      e_good_job = described_class.enqueue(ExampleJob.new(true, raise_error: true))
      errored_good_job, errored_result, errored_error = described_class.all.perform_with_advisory_lock

      expect(errored_good_job).to eq e_good_job
      expect(errored_result).to eq nil
      expect(errored_error).to be_an ExpectedError
    end
  end

  describe '#perform' do
    let(:active_job) { ExampleJob.new("a string") }
    let!(:good_job) { described_class.enqueue(active_job) }

    it 'returns the results of the job' do
      result, error = good_job.perform

      expect(result).to eq "a string"
      expect(error).to be_nil
    end

    it 'destroys the job' do
      good_job.perform
      expect { good_job.reload }.to raise_error ActiveRecord::RecordNotFound
    end

    it 'can preserve the job' do
      good_job.perform(destroy_after: false)
      expect(good_job.reload).to have_attributes(
        performed_at: within(1.second).of(Time.current),
        finished_at: within(1.second).of(Time.current)
      )
    end

    it 'raises an error if the job is attempted to be re-run' do
      good_job.update!(finished_at: Time.current)
      expect { good_job.perform }.to raise_error described_class::PreviouslyPerformedError
    end

    context 'when ActiveJob rescues an error' do
      let(:active_job) { ExampleJob.new("a string", raise_error: true) }

      before do
        ExampleJob.retry_on StandardError, wait: 0, attempts: Float::INFINITY
      end

      it 'returns the results of the job' do
        result, error = good_job.perform

        expect(result).to be_nil
        expect(error).to be_a(ExpectedError)
      end

      it 'destroys the job' do
        good_job.perform

        expect { good_job.reload }.to raise_error ActiveRecord::RecordNotFound
      end

      it 'can preserve the job' do
        good_job.perform(destroy_after: false)

        expect(good_job.reload).to have_attributes(
          error: "ExpectedError: Raised expected error",
          performed_at: within(1.second).of(Time.current),
          finished_at: within(1.second).of(Time.current)
        )
      end
    end

    context 'when ActiveJob raises an error' do
      let(:active_job) { ExampleJob.new("a string", raise_error: true) }

      it 'returns the results of the job' do
        result, error = good_job.perform

        expect(result).to be_nil
        expect(error).to be_a(ExpectedError)
      end

      describe 'GoodJob.reperform_jobs_on_standard_error behavior' do
        context 'when true' do
          it 'leaves the job record unfinished' do
            good_job.perform(destroy_after: false)

            expect(good_job.reload).to have_attributes(
              error: "ExpectedError: Raised expected error",
              performed_at: within(1.second).of(Time.current),
              finished_at: nil
            )
          end

          it 'does not destroy the job record' do
            good_job.perform(destroy_after: true)
            expect { good_job.reload }.not_to raise_error
          end
        end

        context 'when false' do
          it 'destroys the job' do
            good_job.perform(destroy_after: true, reperform_on_standard_error: false)
            expect { good_job.reload }.to raise_error ActiveRecord::RecordNotFound
          end

          it 'can preserve the job' do
            good_job.perform(destroy_after: false, reperform_on_standard_error: false)

            expect(good_job.reload).to have_attributes(
              error: "ExpectedError: Raised expected error",
              performed_at: within(1.second).of(Time.current),
              finished_at: within(1.second).of(Time.current)
            )
          end
        end
      end
    end
  end
end
