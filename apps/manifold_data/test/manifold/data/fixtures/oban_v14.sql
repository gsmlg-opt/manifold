CREATE TYPE oban_job_state AS ENUM (
  'available', 'suspended', 'scheduled', 'executing', 'retryable',
  'completed', 'discarded', 'cancelled'
);

-- Storage contract of Oban 2.24.1, without loading the removed dependency.
CREATE TABLE oban_jobs (
  id bigserial PRIMARY KEY,
  state oban_job_state NOT NULL DEFAULT 'available',
  queue text NOT NULL DEFAULT 'default',
  worker text NOT NULL,
  args jsonb NOT NULL DEFAULT '{}',
  meta jsonb DEFAULT '{}',
  tags text[] DEFAULT '{}',
  errors jsonb[] NOT NULL DEFAULT '{}',
  attempt integer NOT NULL DEFAULT 0,
  attempted_by text[],
  max_attempts integer NOT NULL DEFAULT 20,
  priority integer NOT NULL DEFAULT 0,
  inserted_at timestamp NOT NULL DEFAULT timezone('UTC', now()),
  scheduled_at timestamp NOT NULL DEFAULT timezone('UTC', now()),
  attempted_at timestamp,
  completed_at timestamp,
  discarded_at timestamp,
  cancelled_at timestamp,
  CONSTRAINT worker_length CHECK (char_length(worker) > 0 AND char_length(worker) < 128),
  CONSTRAINT queue_length CHECK (char_length(queue) > 0 AND char_length(queue) < 128),
  CONSTRAINT non_negative_priority CHECK (priority >= 0),
  CONSTRAINT positive_max_attempts CHECK (max_attempts > 0),
  CONSTRAINT attempt_range CHECK (attempt BETWEEN 0 AND max_attempts)
);

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index
  ON oban_jobs(state, queue, priority, scheduled_at, id);
CREATE INDEX oban_jobs_args_index ON oban_jobs USING gin(args);
CREATE INDEX oban_jobs_meta_index ON oban_jobs USING gin(meta);
CREATE INDEX oban_jobs_state_cancelled_at_index ON oban_jobs(state, cancelled_at);
CREATE INDEX oban_jobs_state_discarded_at_index ON oban_jobs(state, discarded_at);
COMMENT ON TABLE oban_jobs IS '14';

CREATE UNLOGGED TABLE oban_peers (
  name text PRIMARY KEY,
  node text NOT NULL,
  started_at timestamp NOT NULL,
  expires_at timestamp NOT NULL
);
