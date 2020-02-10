alter table invoices add column replaces_id varchar(64);
alter table invoices add column replaced_by_id varchar(64);
