# Bloomington Babysitting Co-op Clerk - Backend
Created for Cloudflare Pages + Supabase + Resend.

## Setup
### Link to Remote Project
```
npx supabase link --project-ref <your-project-ref>
```

### Local Development
1. Clone this repo
2. Install dependencies
   ```
   npm install -g npm-check-updates
   ncu -u
   npm install
   ```
3. Ensure Docker Desktop is running
4. Start the local Supabase stack
   ```
   npx supabase start
   ```
5. Open a browser to http://localhost:54323 to view Supabase Studio
6. Create local migrations with `npx supabase migration new <name>`
7. Push migrations to local with `npx supabase db push --local`
8. Wipe and reset the local db with `npx supabase db reset --local`

## Deploy
1. Push migrations to remote with `npx supabase db push`
2. Push functions to remote with `npx supabase functions deploy send-email`

### Initial Setup
1. Create an initial user in the [Supabase Authentication dashboard](https://supabase.com/dashboard/project/_/auth/users)
2. Open the [Supabase Storage Files dashboard](https://supabase.com/dashboard/project/_/storage/files) and create a private bucket named `family-photos`
3. Open the [Supabase SQL Editor dashboard](https://supabase.com/dashboard/project/_/sql) and run the below (changing the email)
   ```
   select public.rpc_bootstrap_admin('admin@gmail.com');
   select gen_random_uuid();
   ```
4. Copy the `gen_random_uuid` result into the `WEBHOOK_KEY` value in `.env`
5. Create a [Resend API key](https://resend.com/api-keys) and paste into the `RESEND_API_KEY` value in `.env`
   * This is to make the send-email edge function work
6. Link Supabase to Resend in the [Resend Integrations dashboard](https://resend.com/settings/integrations)
   * This is to make integrated auth api emails work (reset password, etc)
7. Open the [Supabase Edge Functions Secrets dashboard](https://supabase.com/dashboard/project/_/functions/secrets) and add `FRONTEND_URL`, `RESEND_FROM_EMAIL`, `RESEND_API_KEY` and `WEBHOOK_KEY` with remote values from `.env`
8. Open the [Supabase Webhooks dashboard](https://supabase.com/dashboard/project/_/integrations/webhooks/webhooks) and click `Create a new hook`
   * Name: `send-email-queue`
   * Table: `public email_queue`
   * Events: `Insert`
   * Type: `Supabase Edge Functions`
   * Method: `POST`
   * Function: `send-email`
   * Add a new HTTP Header with 
      * Key: `x-supabase-webhook-source`
      * Value: copied from remote `WEBHOOK_KEY` value in `.env`