GRANT ALL PRIVILEGES ON app.* TO 'app-sa'@'%';
create table app.payload(tst timestamp, value varchar(100));
insert into app.payload(tst, value) values (now(), 'initial-value');