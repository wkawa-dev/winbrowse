CREATE TABLE breakage_reports (
  id TEXT PRIMARY KEY,
  received_at TEXT NOT NULL,
  site TEXT NOT NULL,
  app_version TEXT NOT NULL,
  system TEXT NOT NULL,
  report TEXT NOT NULL
);
CREATE INDEX breakage_reports_by_site ON breakage_reports (site, received_at);
