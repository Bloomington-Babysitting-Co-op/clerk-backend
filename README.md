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

## Bootstrap
1. Create an initial user in the [Supabase Authentication dashboard](https://supabase.com/dashboard/project/_/auth/users)
2. Open the [Supabase Storage Files dashboard](https://supabase.com/dashboard/project/_/storage/files) and create a private bucket named `family-photos`
3. Open the [Supabase SQL Editor dashboard](https://supabase.com/dashboard/project/_/sql) and run the below (changing the email)
   ```
   SELECT public.rpc_bootstrap_admin('admin@gmail.com');
   ```
