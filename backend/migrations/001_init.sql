-- SOLVANTA backend — initial schema (doc §52–54: PostgreSQL).
-- The API ships with an in-memory store for development; applying this schema
-- is the production path. Enum-like columns use CHECK constraints mirroring
-- the Dart enum .name values in the client.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- School & tenancy (doc §8)
CREATE TABLE IF NOT EXISTS schools (
    id        TEXT PRIMARY KEY,
    name      TEXT NOT NULL,
    motto     TEXT,
    address   TEXT,
    phone     TEXT,
    email     TEXT,
    region    TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS school_terms (
    id         BIGSERIAL PRIMARY KEY,
    school_id  TEXT NOT NULL REFERENCES schools(id),
    year       TEXT NOT NULL,
    name       TEXT NOT NULL,
    start_date DATE NOT NULL,
    end_date   DATE NOT NULL
);

-- Users & RBAC (doc §9). Passwords MUST be hashed (bcrypt/argon2) in prod.
CREATE TABLE IF NOT EXISTS users (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    email      TEXT NOT NULL UNIQUE,
    phone      TEXT,
    password   TEXT NOT NULL,           -- hashed in production
    role       TEXT NOT NULL CHECK (role IN
        ('superAdmin','schoolAdmin','headteacher','teacher','parent','student','staff','educationAuthority')),
    school_id  TEXT REFERENCES schools(id),
    class_id   TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Classes (SIS)
CREATE TABLE IF NOT EXISTS class_rooms (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    stream     TEXT,
    teacher_id TEXT REFERENCES users(id)
);

-- Students (doc §10)
CREATE TABLE IF NOT EXISTS students (
    id            TEXT PRIMARY KEY,
    first_name    TEXT NOT NULL,
    last_name     TEXT NOT NULL,
    gender        TEXT,
    date_of_birth DATE,
    admission_date DATE,
    admission_no  TEXT,
    class_id      TEXT REFERENCES class_rooms(id),
    school_id     TEXT NOT NULL REFERENCES schools(id),
    status        TEXT NOT NULL DEFAULT 'active',
    parent_user_id TEXT REFERENCES users(id)
);

-- Users ↔ students links (doc §9). Declared after students (forward FK).
CREATE TABLE IF NOT EXISTS user_students (
    user_id    TEXT NOT NULL REFERENCES users(id),
    student_id TEXT NOT NULL REFERENCES students(id),
    PRIMARY KEY (user_id, student_id)
);

-- Guardians / contacts / authorized pickup (doc §13)
CREATE TABLE IF NOT EXISTS student_contacts (
    id           BIGSERIAL PRIMARY KEY,
    student_id   TEXT NOT NULL REFERENCES students(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind IN ('guardian','emergency','authorizedPickup')),
    name         TEXT NOT NULL,
    phone        TEXT,
    relation     TEXT
);

-- Attendance (doc §12)
CREATE TABLE IF NOT EXISTS attendance (
    id         TEXT PRIMARY KEY,
    student_id TEXT NOT NULL REFERENCES students(id),
    class_id   TEXT NOT NULL REFERENCES class_rooms(id),
    date       DATE NOT NULL,
    status     TEXT NOT NULL CHECK (status IN ('present','late','absent','excused')),
    check_in   TIME,
    check_out  TIME,
    old_status TEXT,
    reason     TEXT,
    UNIQUE (student_id, date)
);

-- Gate & safety (doc §13)
CREATE TABLE IF NOT EXISTS gate_events (
    id         TEXT PRIMARY KEY,
    student_id TEXT NOT NULL REFERENCES students(id),
    type       TEXT NOT NULL CHECK (type IN
        ('arrival','departure','pickupAuthorized','unauthorizedPickup','earlyDeparture')),
    time       TIME NOT NULL,
    date       DATE NOT NULL,
    reporter   TEXT,
    person     TEXT,
    detail     TEXT
);

-- Question bank (doc §17)
CREATE TABLE IF NOT EXISTS questions (
    id              TEXT PRIMARY KEY,
    type            TEXT NOT NULL CHECK (type IN
        ('mcq','trueFalse','fillBlank','shortAnswer','structured','math','essay','practical')),
    subject_id      TEXT NOT NULL,
    class_id        TEXT,
    topic           TEXT NOT NULL,
    difficulty      INT  NOT NULL DEFAULT 1,
    cognitive_level TEXT,
    marks           NUMERIC(6,2) NOT NULL DEFAULT 1,
    stem            TEXT NOT NULL,
    options         JSONB,
    correct_answer  TEXT,
    explanation     TEXT,
    marking_scheme  TEXT,
    status          TEXT NOT NULL DEFAULT 'approved',
    created_by      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- AI question-generation requests (doc §43)
CREATE TABLE IF NOT EXISTS question_gen_requests (
    id             TEXT PRIMARY KEY,
    requester_id   TEXT NOT NULL REFERENCES users(id),
    subject_id     TEXT NOT NULL,
    topic          TEXT NOT NULL,
    type           TEXT NOT NULL,
    count          INT NOT NULL,
    priority       TEXT NOT NULL DEFAULT 'normal',
    class_id       TEXT,
    created_at     TEXT,
    published_at   TEXT,
    status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN
        ('pending','generated','published','rejected')),
    drafts         JSONB
);

-- Assessments (doc §16)
CREATE TABLE IF NOT EXISTS assessments (
    id         TEXT PRIMARY KEY,
    title      TEXT NOT NULL,
    type       TEXT NOT NULL CHECK (type IN
        ('exercise','homework','quiz','classTest','midTerm','endTerm','mock','diagnostic','remedial','vacation')),
    subject_id TEXT NOT NULL,
    class_id   TEXT NOT NULL REFERENCES class_rooms(id),
    date       DATE NOT NULL,
    created_by TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS assessment_questions (
    assessment_id TEXT NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    question_id   TEXT NOT NULL REFERENCES questions(id),
    position      INT NOT NULL,
    PRIMARY KEY (assessment_id, question_id)
);

-- Paper scans → background marking jobs (doc §20, §54)
CREATE TABLE IF NOT EXISTS scan_jobs (
    id            TEXT PRIMARY KEY,
    assessment_id TEXT NOT NULL REFERENCES assessments(id),
    student_id    TEXT NOT NULL REFERENCES students(id),
    status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN
        ('queued','processing','ready','retake_needed')),
    pages         INT NOT NULL DEFAULT 0,
    object_key    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Submissions & verdicts (doc §26)
CREATE TABLE IF NOT EXISTS submissions (
    id            TEXT PRIMARY KEY,
    assessment_id TEXT NOT NULL REFERENCES assessments(id),
    student_id    TEXT NOT NULL REFERENCES students(id),
    class_id      TEXT NOT NULL REFERENCES class_rooms(id),
    date          DATE NOT NULL,
    answers       JSONB NOT NULL,
    teacher_marks JSONB NOT NULL DEFAULT '{}'::jsonb,
    earned        NUMERIC(8,2) NOT NULL DEFAULT 0,
    confidence    NUMERIC(5,4),
    status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN
        ('pending','auto_marked','verdicts_pending','marked','rejected')),
    UNIQUE (assessment_id, student_id)
);

-- Learning gaps & interventions (doc §27–32)
CREATE TABLE IF NOT EXISTS interventions (
    id              TEXT PRIMARY KEY,
    student_id      TEXT NOT NULL REFERENCES students(id),
    topic           TEXT NOT NULL,
    action          TEXT NOT NULL,
    assigned_by     TEXT,
    created_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN
        ('open','inProgress','completed','cancelled')),
    reassessment_assessment_id TEXT REFERENCES assessments(id)
);

-- Communication (doc §40)
CREATE TABLE IF NOT EXISTS announcements (
    id            TEXT PRIMARY KEY,
    title         TEXT NOT NULL,
    body          TEXT NOT NULL,
    audience      TEXT NOT NULL DEFAULT 'school' CHECK (audience IN ('school','classes','emergency')),
    target_class_id TEXT,
    author_id     TEXT NOT NULL REFERENCES users(id),
    -- App-facing display string (e.g. "2026-09-11T08:15"), stored as-is.
    timestamp     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id           TEXT PRIMARY KEY,
    from_id      TEXT NOT NULL REFERENCES users(id),
    to_id        TEXT NOT NULL REFERENCES users(id),
    related_student_id TEXT REFERENCES students(id),
    subject      TEXT,
    body         TEXT NOT NULL,
    timestamp    TEXT NOT NULL,
    read         BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS notifications (
    id         TEXT PRIMARY KEY,
    kind       TEXT NOT NULL CHECK (kind IN
        ('gate','attendance','assessment','marking','intervention','message','assignment','announcement','system')),
    title      TEXT NOT NULL,
    body       TEXT,
    timestamp  TEXT NOT NULL,
    student_id TEXT REFERENCES students(id),
    user_id    TEXT REFERENCES users(id),
    read       BOOLEAN NOT NULL DEFAULT FALSE
);

-- Assignments (doc §41)
CREATE TABLE IF NOT EXISTS assignments (
    id           TEXT PRIMARY KEY,
    class_id     TEXT NOT NULL REFERENCES class_rooms(id),
    subject_id   TEXT NOT NULL,
    title        TEXT NOT NULL,
    instructions TEXT,
    deadline     DATE NOT NULL,
    created_by   TEXT,
    created_at   TEXT
);

CREATE TABLE IF NOT EXISTS assignment_completions (
    assignment_id TEXT NOT NULL REFERENCES assignments(id) ON DELETE CASCADE,
    student_id    TEXT NOT NULL REFERENCES students(id),
    completed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (assignment_id, student_id)
);

-- Audit trail (doc §49) — append-only
CREATE TABLE IF NOT EXISTS audit_logs (
    id         BIGSERIAL PRIMARY KEY,
    action     TEXT NOT NULL,
    actor      TEXT NOT NULL,
    target     TEXT,
    detail     TEXT,
    reason     TEXT,
    timestamp  TEXT NOT NULL
);

-- Refresh-token sessions (auth state; tokens stored as SHA-256 hashes only)
CREATE TABLE IF NOT EXISTS refresh_tokens (
    hash       TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_students_class   ON students(class_id);
CREATE INDEX IF NOT EXISTS idx_attendance_date  ON attendance(date);
CREATE INDEX IF NOT EXISTS idx_gate_student_date ON gate_events(student_id, date);
CREATE INDEX IF NOT EXISTS idx_submissions_assessment ON submissions(assessment_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, read);
CREATE INDEX IF NOT EXISTS idx_messages_user ON messages(to_id, timestamp DESC);