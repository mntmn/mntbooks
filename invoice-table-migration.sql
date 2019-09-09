
-- drop table invoices;

create table invoices (
        id varchar(64) not null primary key,
        invoice_date varchar(23),
        amount_cents int,
        details text,
        currency varchar(4),
        tax_code varchar(8),
        sales_account varchar(32),
        order_id  varchar (32),
        payment_method  varchar (32),
        line_items text,
        customer_account varchar(32),
        customer_company text,
        customer_name  text,
        customer_address_1 text,
        customer_address_2 text,
        customer_zip text,
        customer_city  text,
        customer_state text,
        customer_country text,
        vat_included varchar(6)
      );

insert into invoices 
select invoice_id as id,date,amount_cents,details,currency,tax_code,credit_account as sales_account,
order_id,
invoice_payment_method as payment_method,
invoice_lines as line_items,
debit_account as customer_account,
invoice_company as customer_company,
invoice_name as customer_name,
invoice_address_1 as customer_address_1,
invoice_address_2 as customer_address_2,
invoice_zip as customer_zip,
invoice_city as customer_city,
invoice_state as customer_state,
invoice_country as customer_country,
"true"
from book where invoice_id not null;

delete from book where invoice_id not null;

delete from book where credit_account like "customer:%" and debit_txn_id is null;

delete from book where debit_account="invalid";

delete from book where credit_account="invalid";

update book set amount_cents=-amount_cents where amount_cents<0;
