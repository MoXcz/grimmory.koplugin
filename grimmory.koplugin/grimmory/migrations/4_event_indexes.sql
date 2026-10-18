CREATE INDEX IF NOT EXISTS book_session_book_id ON book_session (book_id);

CREATE INDEX IF NOT EXISTS book_event_session_id ON book_event (session_id);
