// Merges wiring.json into Seerr's settings.json before Seerr starts; never logs API keys.
const fs = require('fs');

const SETTINGS = '/app/config/settings.json';
const wiring = JSON.parse(fs.readFileSync('/seerr-wiring/wiring.json', 'utf8'));

if (!fs.existsSync(SETTINGS)) {
  console.log('settings.json missing (first boot); finish the setup wizard, then restart to apply wiring');
  process.exit(0);
}

const before = fs.readFileSync(SETTINGS, 'utf8');
const settings = JSON.parse(before);

for (const kind of ['sonarr', 'radarr']) {
  const list = (settings[kind] ||= []);
  for (const want of wiring[kind] || []) {
    const apiKey = process.env[want.apiKeyEnv] || '';
    const enforce = { ...want.enforce, ...(apiKey && { apiKey }) };
    // Instances are matched on hostname so UI-made extra instances are left alone.
    const cur = list.find((i) => i.hostname === enforce.hostname);
    if (cur) {
      Object.assign(cur, enforce);
      console.log(`${kind}/${enforce.hostname}: enforced ${Object.keys(enforce).join(',')}`);
    } else if (apiKey) {
      const id = list.length ? Math.max(...list.map((i) => i.id)) + 1 : 0;
      list.push({ ...want.createOnly, ...enforce, id });
      console.log(`${kind}/${enforce.hostname}: created id=${id}`);
    } else {
      console.log(`${kind}/${enforce.hostname}: missing, and ${want.apiKeyEnv} is unset; skipped`);
    }
  }
}

if (wiring.jellyfin && settings.jellyfin) {
  Object.assign(settings.jellyfin, wiring.jellyfin);
  console.log(`jellyfin: enforced ${Object.keys(wiring.jellyfin).join(',')}`);
}

const after = JSON.stringify(settings, undefined, ' ');
if (after === before) {
  console.log('settings.json unchanged');
} else {
  // Same-directory rename so a crash can't leave Seerr a half-written settings.json.
  fs.writeFileSync(`${SETTINGS}.wiring-tmp`, after);
  fs.renameSync(`${SETTINGS}.wiring-tmp`, SETTINGS);
  console.log('settings.json updated');
}
