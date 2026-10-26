# MONARC Setup Checklist

## 1. Supabase Project
- Create a new Supabase project (free tier is fine).
- In **SQL Editor**, paste and run the three SQL files in order:
  1. `sql/01-schema.sql`
  2. `sql/02-core-rpcs.sql`
  3. `sql/03-admin-rpcs.sql`
- Go to **Storage** and confirm the `monarc-product-images` bucket exists and is **public**.
  - If it does not exist, run this in SQL Editor:
    ```sql
    insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
    values ('monarc-product-images','monarc-product-images',true,4194304,array['image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public=true,file_size_limit=4194304,allowed_mime_types=array['image/jpeg','image/png','image/webp'];
    ```

## 2. Owner Account
- In Supabase **Auth > Users**, create your owner account.
- In **Table Editor > monarc_staff**, insert your owner row:
  ```sql
  insert into public.monarc_staff (user_id,email,display_name,role,active)
  values ('YOUR-USER-UUID-HERE','your@email.com','Owner','owner',true);
  ```
- Replace `YOUR-USER-UUID-HERE` with the UUID from Auth > Users.

## 3. Config
- Open `config.js` and replace the placeholders with your Supabase **Project URL** and **anon/public key**.
  - Find these in Supabase **Settings > API**.
  - **Never** paste a `service_role` or `secret` key here.

## 4. Deploy
- Push this folder to a **private** GitHub repository.
- In repo **Settings > Pages**, set source to `main` branch and root folder.
- Wait 1–2 minutes; your site will be live at `https://<username>.github.io/<repo>/`.
- Alternative: drag the folder onto **https://app.netlify.com/drop** for instant hosting.

## 5. Admin Access
- Open `dashboard.html` on your live URL.
- Sign in with the owner account you created in Supabase Auth.
- Go to **Settings** to configure:
  - Shop name (FR/EN/AR)
  - WhatsApp number (format: `213XXXXXXXXX`)
  - Contact email
  - Payment methods (COD / CCP)
  - Returns policy
  - Meta Pixel ID (optional)
  - Store open/closed toggle

## 6. Add Products
- In the admin dashboard, go to **Products**.
- Click **Add product**, fill the multilingual text, price, and variants.
- Upload a photo (stored in Supabase Storage).
- Save. Products appear on the storefront immediately.

## 7. Connect Facebook / Instagram
- In **Settings**, paste your **Meta Pixel ID**.
- Save. The pixel script is injected automatically.
- For Instagram Shopping / Facebook Shop, use Meta **Commerce Manager** to connect your catalog URL after publishing.

## Notes
- Checkout is disabled until you fill real products and set **Store open** to true.
- Orders route to **WhatsApp** and appear in the admin **Orders** panel.
- Stock is reserved on order confirmation and released on cancellation.
- All changes from the dashboard are saved through audited Supabase RPCs.
