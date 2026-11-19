# Kellerfriseur Terminbuchung – Version 2

## Enthalten
- `public/index.html`: Kundenkalender (Wochen-/Monatsansicht), 30 Tage Buchungsvorlauf, Startzeiten im 15-Minuten-Raster, Anfrageformular, Admin-Login und Admin-Oberfläche.
- `netlify/functions/api.mjs`: serverseitige API; Supabase Service-Role bleibt serverseitig.
- `supabase.sql`: Tabellen, RLS, Verfügbarkeits- und Buchungsfunktionen mit Überschneidungsschutz.
- `netlify.toml`: Netlify-Publish- und Functions-Konfiguration.

## Netlify-Deployment
1. ZIP entpacken.
2. Gesamten Inhalt des Ordners in ein privates GitHub-Repository laden.
3. In Netlify: **Add new project → Import an existing project → GitHub** und das Repository wählen.
4. Build command leer lassen; Publish directory `public`; Functions directory `netlify/functions`.
5. Environment variables in Netlify unter **Project configuration → Environment variables** eintragen:
   - `SUPABASE_URL` = Project URL
   - `SUPABASE_SERVICE_ROLE_KEY` = Supabase Secret/service_role key (nur serverseitig!)
   - `RESEND_API_KEY` = Resend API Key
   - `EMAIL_FROM` = verifizierter Absender, z. B. `Kellerfriseur <termine@deine-domain.de>`
   - `ADMIN_NOTIFICATION_EMAILS` = `lcordella818@gmail.com` (mehrere Adressen kommasepariert)
6. Deploy auslösen.

## Supabase
1. Supabase Dashboard → SQL Editor → New query.
2. Gesamte `supabase.sql` einfügen und Run ausführen.
3. Unter **Authentication → Users** Benutzer für Hauptadmin und Friseur anlegen (Einladung oder Benutzererstellung durch Projektinhaber; keine öffentliche Registrierung einschalten).
4. Benutzer-UUIDs aus Authentication → Users kopieren.
5. In SQL Editor die beiden Einträge einsetzen und ausführen:

```sql
insert into public.admin_users(user_id, role, active)
values
  ('UUID-DES-HAUPTADMINS', 'owner', true),
  ('UUID-DES-FRISEURS', 'admin', true);
```

6. In Authentication → Providers → Email öffentliche Sign-ups deaktivieren. Admin-Benutzer werden nur vom Projektinhaber angelegt und in `admin_users` freigegeben.

## E-Mail
- `lcordella818@gmail.com` ist zunächst als Admin-Benachrichtigungsadresse hinterlegt.
- Resend-Konto erstellen, Domain verifizieren und API-Key als `RESEND_API_KEY` in Netlify speichern.
- `EMAIL_FROM` muss eine verifizierte Absenderadresse deiner Domain sein. Die Absenderadresse und Admin-Empfänger können später in Netlify geändert werden.
- Ohne gültigen Resend-Key werden Buchungen zwar gespeichert, E-Mails aber nicht versendet. Die E-Mail-Queue/Wiederholungsfunktion ist in dieser Version noch nicht implementiert.

## Wichtige Hinweise zum Funktionsumfang
Diese Version ist ein neuer technischer Grundstand und kein vollständig abgenommener Produktivbetrieb. Vor Live-Nutzung müssen die Endpunkte und SQL-Funktionen mit einem echten Supabase-/Netlify-Projekt getestet werden. Insbesondere sind Kunden-Verwaltungslinks, Kundensuche, wiederkehrende Sperrzeiten, Bearbeiten/Verschieben bestehender Termine, Admin-Einladungs-UI, E-Mail-Retry/Protokollierung und konfigurierbare Termindauer noch nicht vollständig umgesetzt. Die Frontend-Kalendernavigation und einige Admin-Funktionen sind Basisfunktionen.

Die Datenbank erzwingt Überschneidungsfreiheit für aktive Termine. Kunden können über den öffentlichen API-Endpunkt nur Verfügbarkeiten abfragen und neue Anfragen anlegen; private Tabellen sind durch RLS für `anon` und `authenticated` gesperrt.
