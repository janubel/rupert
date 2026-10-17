import React, { useEffect, useRef, useState } from 'react';
import { Alert, AppState, KeyboardAvoidingView, Linking, Platform, Pressable, RefreshControl, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import * as SecureStore from 'expo-secure-store';
import * as Crypto from 'expo-crypto';
// Expo's native fetch enforces redirect:error on both iOS and Android.
import { fetch } from 'expo/fetch';
import { instanceOrigin, localDay, weekBounds } from './src/validation.mjs';

type Login = { origin: string; token: string };
type Entry = { id: number; worked_on: string; hours: string; work_type: string; notes?: string };
type Sheet = { id: number; period_start: string; period_end: string; status: string; total_hours: string; notes?: string; review_note?: string; entries?: Entry[]; history?: { action: string; created_at: string }[] };
type Shift = { id: number; started_at: string; ended_at?: string };
const storageKey = 'rupert.employee.session.v1';
const storageOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
function Field({ label, ...props }: React.ComponentProps<typeof TextInput> & { label: string }) {
  return <View style={s.field}><Text style={s.label}>{label}</Text><TextInput accessibilityLabel={label} style={s.input} placeholderTextColor="#817c72" {...props}/></View>;
}
function Button({ title, onPress, disabled = false, subtle = false }: { title: string; onPress: () => void; disabled?: boolean; subtle?: boolean }) {
  return <Pressable accessibilityRole="button" accessibilityState={{ disabled }} disabled={disabled} onPress={onPress} style={[s.button, subtle && s.subtle, disabled && { opacity: .45 }]}><Text style={[s.buttonText, subtle && { color: '#526145' }]}>{title}</Text></Pressable>;
}
export default function App() { return <SafeAreaProvider><EmployeeApp/></SafeAreaProvider>; }
function EmployeeApp() {
  const [login, setLogin] = useState<Login | null>(null);
  const [origin, setOrigin] = useState(process.env.EXPO_PUBLIC_RUPERT_URL || '');
  const [email, setEmail] = useState(''); const [password, setPassword] = useState('');
  const [ready, setReady] = useState(false); const [busy, setBusy] = useState(false); const [message, setMessage] = useState('');
  const [sheets, setSheets] = useState<Sheet[]>([]); const [sheet, setSheet] = useState<Sheet | null>(null); const [shifts, setShifts] = useState<Shift[]>([]);
  const [name, setName] = useState(''); const [workspace, setWorkspace] = useState('');
  const [creating, setCreating] = useState(false); const [period, setPeriod] = useState(weekBounds()); const [notes, setNotes] = useState('');
  const [editingEntry, setEditingEntry] = useState<number | null>(null);
  const [date, setDate] = useState(localDay()); const [hours, setHours] = useState('8'); const [type, setType] = useState('regular'); const [entryNotes, setEntryNotes] = useState('');
  const [correction, setCorrection] = useState<Shift | null>(null); const [startTime, setStartTime] = useState(''); const [endTime, setEndTime] = useState(''); const [reason, setReason] = useState('');
  const gate = useRef(false); const sheetRef = useRef<Sheet | null>(null); const loginRef = useRef<Login | null>(null);
  useEffect(() => { loginRef.current = login; }, [login]);
  useEffect(() => { sheetRef.current = sheet; if (sheet) setSheets(rows => rows.map(row => row.id === sheet.id ? sheet : row)); }, [sheet]);
  useEffect(() => { SecureStore.getItemAsync(storageKey).then(value => {
    if (value) { const saved = JSON.parse(value) as Login; instanceOrigin(saved.origin); setOrigin(saved.origin); setLogin(saved); }
  }).catch(() => setMessage('Sign in to reconnect your staff account.')).finally(() => setReady(true)); }, []);
  async function clearSession() {
    loginRef.current = null; setLogin(null); setSheets([]); setSheet(null); setShifts([]); setCreating(false); setCorrection(null); setPassword('');
    await SecureStore.deleteItemAsync(storageKey);
  }
  async function api(path: string, method = 'GET', body?: unknown, credentials = loginRef.current) {
    if (!credentials) throw new Error('Sign in to continue.');
    const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(`${credentials.origin}/api/v1/employee/${path}`, {
        method, credentials: 'omit', redirect: 'error', signal: controller.signal,
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', Authorization: `Bearer ${credentials.token}` },
        ...(body ? { body: JSON.stringify(body) } : {})
      });
      if (response.status === 401) { await clearSession(); throw new Error('Your session expired or was revoked. Sign in again.'); }
      const data = response.status === 204 ? {} : await response.json();
      if (!response.ok) throw new Error(data.message || data.error || 'Request failed.');
      return data;
    } catch (error) {
      if (controller.signal.aborted) throw new Error('Connection timed out. Refresh to check whether the change was saved before retrying.');
      throw error;
    } finally { clearTimeout(timeout); }
  }
  async function run(action: () => Promise<void>) {
    if (gate.current) return; gate.current = true; setBusy(true); setMessage('');
    try { await action(); } catch (error) { setMessage(error instanceof Error ? error.message : 'Unable to connect. Check your connection and try again.'); }
    finally { gate.current = false; setBusy(false); }
  }
  async function refresh(credentials = loginRef.current) {
    const [me, list, clock] = await Promise.all([api('session', 'GET', undefined, credentials), api('timesheets', 'GET', undefined, credentials), api('clock', 'GET', undefined, credentials)]);
    if (credentials !== loginRef.current) return;
    setName(me.employee.name); setWorkspace(me.workspace.name); setSheets(list.data); setShifts(clock.data);
  }
  useEffect(() => { if (login) { loginRef.current = login; void run(() => refresh(login)); } }, [login]);
  useEffect(() => { const subscription = AppState.addEventListener('change', state => { if (state === 'active' && loginRef.current) void run(async () => { await refresh(); const id = sheetRef.current?.id; if (id) { const result = await api(`timesheets/${id}`); if (sheetRef.current?.id === id) setSheet(result.data); } }); }); return () => subscription.remove(); }, []);
  async function signIn() {
    const cleanOrigin = instanceOrigin(origin);
    const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(`${cleanOrigin}/api/v1/employee/session`, { method: 'POST', credentials: 'omit', redirect: 'error', signal: controller.signal,
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify({ email: email.trim(), password, device_name: `${Platform.OS === 'ios' ? 'iPhone / iPad' : 'Android'} app` }) });
      const data = await response.json();
      if (!response.ok) throw new Error(data.message || (response.status === 429 ? 'Too many attempts. Try again in 15 minutes.' : 'Check your email and password.'));
      const credentials = { origin: cleanOrigin, token: data.token };
      await SecureStore.setItemAsync(storageKey, JSON.stringify(credentials), storageOptions);
      setPassword(''); setLogin(credentials);
    } finally { clearTimeout(timeout); }
  }
  async function openSheet(id: number) {
    const data = await api(`timesheets/${id}`); setSheet(data.data); setPeriod({ period_start: data.data.period_start, period_end: data.data.period_end }); setNotes(data.data.notes || ''); setCreating(false); resetEntry();
  }
  function resetEntry() { setEditingEntry(null); setDate(localDay()); setHours('8'); setType('regular'); setEntryNotes(''); }
  async function sheetAction(action: string) {
    const data = await api(`timesheets/${sheet!.id}/actions/${action}`, 'POST'); setSheet(data.data); await refresh(); setMessage('Saved.');
  }
  function confirm(title: string, action: () => Promise<void>) {
    Alert.alert(title, 'Continue with this action?', [{ text: 'Cancel', style: 'cancel' }, { text: 'Continue', onPress: () => void run(action) }]);
  }
  const openShift = shifts.find(item => !item.ended_at);
  return <SafeAreaView style={s.safe}><KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
    <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={s.page} refreshControl={login ? <RefreshControl refreshing={busy} onRefresh={() => void run(async () => { await refresh(); if (sheet) await openSheet(sheet.id); })}/> : undefined}>
      <Text style={s.brand}>RUPERT EMPLOYEE</Text>
      <Text style={s.title}>{login ? `Hello, ${name || 'there'}` : 'Your time, in one place'}</Text>
      <Text style={s.caption}>{login ? workspace : 'Sign in to your Rupert instance to record and submit your hours.'}</Text>
      {!!message && <Text accessibilityRole="alert" style={s.notice}>{message}</Text>}
      {!ready ? <Text>Opening your account…</Text> : !login ? <View style={s.card}>
        <Field label="Rupert instance address" placeholder="https://rupert.example.com" value={origin} onChangeText={setOrigin} autoCapitalize="none" keyboardType="url" autoCorrect={false}/>
        <Field label="Staff email" value={email} onChangeText={setEmail} autoCapitalize="none" keyboardType="email-address" autoComplete="email" autoCorrect={false}/>
        <Field label="Password" value={password} onChangeText={setPassword} secureTextEntry autoComplete="current-password"/>
        <Button title="Sign in" disabled={busy || !origin || !email || !password} onPress={() => void run(signIn)}/>
        <Text style={s.caption}>New staff member or forgot your password? Ask your administrator for a private setup link. Set your password on the Rupert website, then sign in here.</Text>
      </View> : <>
        <View style={s.row}><Button title="Timesheets" subtle onPress={() => { setSheet(null); setCreating(false); }}/><Button title="Sign out" subtle disabled={busy} onPress={() => void run(async () => { try { await api('session', 'DELETE'); } finally { await clearSession(); } })}/></View>
        {!sheet && !creating && <>
          <View style={s.card}><Text style={s.heading}>Time clock</Text><Text>{openShift ? `Clocked in ${new Date(openShift.started_at).toLocaleString()}` : 'You are clocked out.'}</Text>
            <Button title={openShift ? 'Clock out' : 'Clock in'} disabled={busy} onPress={() => void run(async () => {
              if (openShift) await api(`clock/${openShift.id}`, 'PATCH');
              else await api('clock', 'POST', { request_token: Crypto.randomUUID() });
              await refresh(); setMessage('Clock saved.');
            })}/>
          </View>
          <Button title="New timesheet" disabled={busy} onPress={() => { setPeriod(weekBounds()); setNotes(''); setCreating(true); }}/>
          <Text style={s.heading}>My timesheets</Text>
          {!sheets.length && <Text>No timesheets yet. Create one for your first work week.</Text>}
          {sheets.map(item => <Pressable accessibilityRole="button" key={item.id} style={s.card} disabled={busy} onPress={() => void run(() => openSheet(item.id))}><Text style={s.heading}>{item.period_start} → {item.period_end}</Text><Text>{item.status.toUpperCase()} · {item.total_hours} hours</Text></Pressable>)}
          <Text style={s.heading}>Recent clock shifts</Text>
          {shifts.slice(0, 20).map(item => <View key={item.id} style={s.card}><Text>{new Date(item.started_at).toLocaleString()} → {item.ended_at ? new Date(item.ended_at).toLocaleString() : 'Open'}</Text><Button title="Request correction" subtle disabled={busy} onPress={() => { setCorrection(item); setStartTime(''); setEndTime(''); setReason(''); }}/></View>)}
          {correction && <View style={s.card}><Text style={s.heading}>Correct shift #{correction.id}</Text><Text>Enter local times as YYYY-MM-DDTHH:MM. A payroll reviewer must approve the change.</Text>
            <Field label="Correct clock-in" value={startTime} onChangeText={setStartTime} placeholder="2026-10-15T09:00"/>
            <Field label="Correct clock-out" value={endTime} onChangeText={setEndTime} placeholder="2026-10-15T17:00"/>
            <Field label="Reason" value={reason} onChangeText={setReason} multiline maxLength={1000}/>
            <Button title="Request correction" disabled={busy || !reason || !startTime || !endTime} onPress={() => void run(async () => { await api(`clock/${correction.id}/corrections`, 'POST', { clock_correction: { proposed_started_at: new Date(startTime).toISOString(), proposed_ended_at: new Date(endTime).toISOString(), reason } }); setCorrection(null); setMessage('Correction requested. Your shift stays unchanged until reviewed.'); })}/>
          </View>}
        </>}
        {(creating || sheet?.status === 'draft') && <View style={s.card}>
          <Text style={s.heading}>{creating ? 'New timesheet' : 'Period & notes'}</Text>
          <Field label="Period starts (YYYY-MM-DD)" value={period.period_start} onChangeText={value => setPeriod({ ...period, period_start: value })}/>
          <Field label="Period ends (YYYY-MM-DD)" value={period.period_end} onChangeText={value => setPeriod({ ...period, period_end: value })}/>
          <Field label="Timesheet notes" value={notes} onChangeText={setNotes} multiline maxLength={4000}/>
          <Button title={creating ? 'Create draft' : 'Save period & notes'} disabled={busy} onPress={() => void run(async () => { const result = await api(creating ? 'timesheets' : `timesheets/${sheet!.id}`, creating ? 'POST' : 'PATCH', { timesheet: { ...period, notes } }); await openSheet(result.data.id); await refresh(); })}/>
        </View>}
        {sheet && <>
          <View style={s.card}><Text style={s.heading}>{sheet.period_start} → {sheet.period_end}</Text><Text>{sheet.status.toUpperCase()} · {sheet.total_hours} hours</Text>{!!sheet.review_note && <Text style={s.notice}>Review: {sheet.review_note}</Text>}{!!sheet.notes && <Text>{sheet.notes}</Text>}</View>
          {sheet.entries?.map(entry => <View key={entry.id} style={s.card}><Text style={s.heading}>{entry.worked_on} · {entry.hours} hours</Text><Text>{entry.work_type} {entry.notes ? `· ${entry.notes}` : ''}</Text>{sheet.status === 'draft' && <View style={s.row}><Button title="Edit" subtle disabled={busy} onPress={() => { setEditingEntry(entry.id); setDate(entry.worked_on); setHours(String(entry.hours)); setType(entry.work_type); setEntryNotes(entry.notes || ''); }}/><Button title="Remove" subtle disabled={busy} onPress={() => confirm('Remove entry?', async () => { const data = await api(`timesheets/${sheet.id}/entries/${entry.id}`, 'DELETE'); setSheet(data.data); resetEntry(); })}/></View>}</View>)}
          {sheet.status === 'draft' && <View style={s.card}><Text style={s.heading}>{editingEntry ? 'Edit entry' : 'Add hours'}</Text>
            <Field label="Date (YYYY-MM-DD)" value={date} onChangeText={setDate}/><Field label="Hours" value={hours} onChangeText={setHours} keyboardType="decimal-pad"/>
            <Text style={s.label}>Work type</Text><View style={s.row}>{['regular','overtime','pto','holiday'].map(value => <Button key={value} title={value === type ? `✓ ${value}` : value} subtle onPress={() => setType(value)}/>)}</View>
            <Field label="Entry notes" value={entryNotes} onChangeText={setEntryNotes} maxLength={1000}/>
            <Button title={editingEntry ? 'Save entry' : 'Add entry'} disabled={busy} onPress={() => void run(async () => { const data = await api(`timesheets/${sheet.id}/entries${editingEntry ? `/${editingEntry}` : ''}`, editingEntry ? 'PATCH' : 'POST', { timesheet_entry: { worked_on: date, hours, work_type: type, notes: entryNotes } }); setSheet(data.data); resetEntry(); })}/>
            <Button title="Import clock shifts" subtle disabled={busy} onPress={() => void run(() => sheetAction('import_shifts'))}/>
            <Text style={s.caption}>Imports closed shifts as regular hours. Check for any manually entered hours before submitting. Classify overtime according to your employer’s policy.</Text>
            <Button title="Submit for review" disabled={busy} onPress={() => confirm('Submit this timesheet?', () => sheetAction('submit'))}/>
            <Button title="Delete draft" subtle disabled={busy} onPress={() => confirm('Delete this draft?', async () => { await api(`timesheets/${sheet.id}`, 'DELETE'); setSheet(null); await refresh(); })}/>
          </View>}
          {sheet.status === 'rejected' && <Button title="Reopen for corrections" disabled={busy} onPress={() => void run(() => sheetAction('reopen'))}/>}
          <View style={s.card}><Text style={s.heading}>History</Text>{sheet.history?.map((event, index) => <Text key={index}>{event.action.replaceAll('_',' ')} · {new Date(event.created_at).toLocaleString()}</Text>)}</View>
        </>}
        <Text style={s.caption}>An internet connection is required. Changes are saved only after the server confirms them.</Text>
        <Button title="Privacy & support" subtle onPress={() => void Linking.openURL(`${login.origin}/employee/privacy`)}/>
        <Button title="Open staff website" subtle onPress={() => void Linking.openURL(`${login.origin}/employee`)}/>
      </>}
    </ScrollView>
  </KeyboardAvoidingView></SafeAreaView>;
}
const s = StyleSheet.create({
  safe: { flex: 1, backgroundColor: '#f6f3eb' }, page: { padding: 22, gap: 16, paddingBottom: 60, maxWidth: 720, width: '100%', alignSelf: 'center' },
  brand: { color: '#526145', fontSize: 12, letterSpacing: 2, fontWeight: '700' }, title: { color: '#292e27', fontSize: 30, fontWeight: '700' },
  caption: { color: '#66675e', fontSize: 14, lineHeight: 21 }, heading: { fontSize: 18, color: '#292e27', fontWeight: '600' },
  card: { backgroundColor: '#fffefa', borderRadius: 20, padding: 18, gap: 12, borderWidth: 1, borderColor: '#deded2' },
  field: { gap: 6 }, label: { color: '#526145', fontWeight: '600' }, input: { borderColor: '#cccfc1', borderWidth: 1, borderRadius: 12, padding: 13, color: '#292e27', fontSize: 16, backgroundColor: '#fff' },
  button: { borderRadius: 24, backgroundColor: '#526145', paddingVertical: 13, paddingHorizontal: 20, minHeight: 48, alignItems: 'center' }, buttonText: { color: '#fffefa', fontWeight: '700', fontSize: 15 },
  subtle: { backgroundColor: '#eaece1' }, row: { flexDirection: 'row', gap: 8, flexWrap: 'wrap' }, notice: { backgroundColor: '#eaece1', color: '#3d4c32', padding: 14, borderRadius: 12, lineHeight: 22 }
});
