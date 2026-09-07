-- TPC-H primary keys, written for PostgreSQL. The kit ships dss.ri, but it
-- targets a TPCD schema and uses DB2 syntax ("ADD FOREIGN KEY <name> (...)"),
-- so it creates NOTHING on PostgreSQL -- it fails at the first ALTER and the
-- rest of the script is a cascade of no-ops. Verified: 0 constraints, 0 indexes.
--
-- PRIMARY KEYS are added because they create the indexes the query planner
-- actually uses, and the TPC-H spec requires them.
-- FOREIGN KEYS are deliberately NOT added: PostgreSQL does not use them for
-- TPC-H plan selection, and validating them against a 60M-row lineitem costs
-- minutes of scanning for no change in memory behaviour. Recorded rather than
-- silently skipped.
ALTER TABLE region   ADD CONSTRAINT region_pk   PRIMARY KEY (r_regionkey);
ALTER TABLE nation   ADD CONSTRAINT nation_pk   PRIMARY KEY (n_nationkey);
ALTER TABLE part     ADD CONSTRAINT part_pk     PRIMARY KEY (p_partkey);
ALTER TABLE supplier ADD CONSTRAINT supplier_pk PRIMARY KEY (s_suppkey);
ALTER TABLE customer ADD CONSTRAINT customer_pk PRIMARY KEY (c_custkey);
ALTER TABLE partsupp ADD CONSTRAINT partsupp_pk PRIMARY KEY (ps_partkey, ps_suppkey);
ALTER TABLE orders   ADD CONSTRAINT orders_pk   PRIMARY KEY (o_orderkey);
ALTER TABLE lineitem ADD CONSTRAINT lineitem_pk PRIMARY KEY (l_orderkey, l_linenumber);
