


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."accept_request"("p_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update public.requests
  set status = 'accepted',
      accepted_by = auth.uid()
  where id = p_request_id
    and status = 'open';
end;
$$;


ALTER FUNCTION "public"."accept_request"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_request"("p_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update public.requests
  set status = 'completed'
  where id = p_request_id
    and status = 'accepted';
end;
$$;


ALTER FUNCTION "public"."complete_request"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_ledger_on_completion"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  hours numeric;
begin
  if NEW.status = 'completed' and OLD.status <> 'completed' then
    hours := extract(epoch from (NEW.end_time - NEW.start_time)) / 3600;

    if hours <= 0 then
      raise exception 'Invalid time range for request %', NEW.id;
    end if;

    insert into public.ledger_entries (request, from_user, to_user, hours)
    values (
      NEW.id,
      NEW.owner,
      NEW.accepted_by,
      hours
    );
  end if;

  return NEW;
end;
$$;


ALTER FUNCTION "public"."create_ledger_on_completion"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."ledger_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request" "uuid" NOT NULL,
    "from_user" "uuid" NOT NULL,
    "to_user" "uuid" NOT NULL,
    "hours" numeric NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ledger_entries_hours_check" CHECK (("hours" > (0)::numeric))
);


ALTER TABLE "public"."ledger_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "family_name" "text",
    "phone" "text",
    "is_admin" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner" "uuid" NOT NULL,
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone NOT NULL,
    "notes" "text",
    "status" "text" NOT NULL,
    "accepted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "accepted_by_valid" CHECK (((("status" = 'accepted'::"text") AND ("accepted_by" IS NOT NULL)) OR (("status" <> 'accepted'::"text") AND ("accepted_by" IS NULL)) OR ("status" = 'completed'::"text"))),
    CONSTRAINT "requests_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'accepted'::"text", 'completed'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "valid_time_range" CHECK (("end_time" > "start_time"))
);


ALTER TABLE "public"."requests" OWNER TO "postgres";


ALTER TABLE ONLY "public"."ledger_entries"
    ADD CONSTRAINT "ledger_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_pkey" PRIMARY KEY ("id");



CREATE INDEX "ledger_from_user_idx" ON "public"."ledger_entries" USING "btree" ("from_user");



CREATE INDEX "ledger_request_idx" ON "public"."ledger_entries" USING "btree" ("request");



CREATE INDEX "ledger_to_user_idx" ON "public"."ledger_entries" USING "btree" ("to_user");



CREATE INDEX "requests_owner_idx" ON "public"."requests" USING "btree" ("owner");



CREATE INDEX "requests_status_idx" ON "public"."requests" USING "btree" ("status");



CREATE OR REPLACE TRIGGER "trg_create_ledger_on_completion" AFTER UPDATE ON "public"."requests" FOR EACH ROW EXECUTE FUNCTION "public"."create_ledger_on_completion"();



ALTER TABLE ONLY "public"."ledger_entries"
    ADD CONSTRAINT "ledger_entries_from_user_fkey" FOREIGN KEY ("from_user") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."ledger_entries"
    ADD CONSTRAINT "ledger_entries_request_fkey" FOREIGN KEY ("request") REFERENCES "public"."requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ledger_entries"
    ADD CONSTRAINT "ledger_entries_to_user_fkey" FOREIGN KEY ("to_user") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_accepted_by_fkey" FOREIGN KEY ("accepted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."requests"
    ADD CONSTRAINT "requests_owner_fkey" FOREIGN KEY ("owner") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE "public"."ledger_entries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ledger_insert" ON "public"."ledger_entries" FOR INSERT WITH CHECK ((("auth"."uid"() = "from_user") OR ("auth"."uid"() = "to_user")));



CREATE POLICY "ledger_select" ON "public"."ledger_entries" FOR SELECT USING (true);



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_select" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



ALTER TABLE "public"."requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "requests_delete" ON "public"."requests" FOR DELETE USING (("auth"."uid"() = "owner"));



CREATE POLICY "requests_insert" ON "public"."requests" FOR INSERT WITH CHECK (("auth"."uid"() = "owner"));



CREATE POLICY "requests_select" ON "public"."requests" FOR SELECT USING (true);



CREATE POLICY "requests_update" ON "public"."requests" FOR UPDATE USING ((("auth"."uid"() = "owner") OR ("auth"."uid"() = "accepted_by") OR (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."is_admin" = true))))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."accept_request"("p_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_request"("p_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_request"("p_request_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_request"("p_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_request"("p_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_request"("p_request_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_ledger_on_completion"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_ledger_on_completion"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_ledger_on_completion"() TO "service_role";


















GRANT ALL ON TABLE "public"."ledger_entries" TO "anon";
GRANT ALL ON TABLE "public"."ledger_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."ledger_entries" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."requests" TO "anon";
GRANT ALL ON TABLE "public"."requests" TO "authenticated";
GRANT ALL ON TABLE "public"."requests" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































drop extension if exists "pg_net";


