import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const MaterialApp(home: Home(), debugShowCheckedModeBanner: false));

const providers = {
  'Groq (free)': ['https://api.groq.com/openai/v1', 'llama-3.3-70b-versatile'],
  'Google Gemini (free)': ['https://generativelanguage.googleapis.com/v1beta/openai', 'gemini-2.0-flash'],
  'OpenRouter (free)': ['https://openrouter.ai/api/v1', 'meta-llama/llama-3.3-70b-instruct:free'],
  'Mistral (free)': ['https://api.mistral.ai/v1', 'mistral-small-latest'],
  'Custom': ['', ''],
};

const systemPrompt = 'You are Jarvis, a friendly voice assistant for an Indian user. '
    'Reply in the same language the user uses (Hindi, English or Hinglish). '
    'Keep answers short because they are read aloud. For legal topics give general '
    'information only and advise consulting a lawyer. Never invent judgments or citations.';

const hindiMap = [
  ['यूट्यूब', 'youtube'], ['गूगल', 'google'], ['जीमेल', 'gmail'], ['व्हाट्सएप', 'whatsapp'],
  ['वॉट्सएप', 'whatsapp'], ['इंस्टाग्राम', 'instagram'], ['फेसबुक', 'facebook'],
  ['चैनल', 'channel'], ['सर्च', 'search'], ['खोजो', 'search'], ['ढूंढो', 'search'],
  ['कोडिंग', 'coding'], ['पाइथन', 'python'], ['कानून', 'law'], ['जजमेंट', 'judgment'],
  ['ड्राफ्ट', 'draft'], ['लीगल नोटिस', 'legal notice'], ['नोटिस', 'notice'],
  ['किराया', 'rent'], ['शिकायत', 'complaint'], ['भेजो', 'bhejo'], ['भेज', 'bhej'],
  ['खोल दो', 'khol do'], ['खोलो', 'khol'], ['खोल', 'khol'], ['चलाओ', 'chalao'],
  ['नोट लिखो', 'note likho'], ['नोट पढो', 'note padho'], ['नोट साफ करो', 'note saaf karo'],
  ['नोट', 'note'], ['बंद करो', 'band karo'], ['अलविदा', 'alvida'],
  ['कितने बजे', 'time'], ['समय', 'time'], ['टाइम', 'time'], ['तारीख', 'date'],
  ['नमस्ते', 'namaste'], ['हैलो', 'hello'], ['कैसे हो', 'kaise ho'], ['तुम कौन हो', 'tum kaun ho'],
  ['धन्यवाद', 'dhanyavad'], ['शुक्रिया', 'shukriya'], ['जार्विस', 'jarvis'], ['जारविस', 'jarvis'],
];

String normalize(String s) {
  var t = s.replaceAll('\u093c', '').toLowerCase().trim();
  final m = [...hindiMap]..sort((a, b) => b[0].length.compareTo(a[0].length));
  for (final p in m) {
    t = t.replaceAll(p[0], p[1]);
  }
  return t.split(RegExp(r'\s+')).join(' ');
}

String removeWords(String t, List<String> w) {
  final set = w.toSet();
  return t.split(' ').where((x) => !set.contains(x)).join(' ');
}

const drafts = {
  'legal notice': {
    'title': 'LEGAL NOTICE',
    'fields': ['sender|Aapka naam', 'receiver|Receiver ka naam', 'receiver_address|Receiver ka address',
      'subject|Subject', 'facts|Facts (kya hua)', 'demand|Demand', 'days|Kitne din me jawab'],
    'body': 'To,\n{receiver}\n{receiver_address}\n\nSubject: {subject}\n\nSir/Madam,\n\n'
        'Facts: {facts}\n\nDemand: {demand}\n\nAap is notice ke {days} din ke andar jawab dein, '
        'anyatha kanooni karyavahi ki jaayegi.\n\nSender: {sender}\nDate: {date}\n',
  },
  'rent agreement': {
    'title': 'RENT AGREEMENT (DRAFT)',
    'fields': ['landlord|Malik ka naam', 'tenant|Kiraydar ka naam', 'address|Property address',
      'rent|Monthly rent (Rs.)', 'deposit|Security deposit (Rs.)', 'months|Kitne mahine'],
    'body': 'This Rent Agreement is made on {date} between:\n\nLandlord: {landlord}\nTenant: {tenant}\n\n'
        'Property: {address}\n\n1. Monthly rent: Rs. {rent}\n2. Security deposit: Rs. {deposit}\n'
        '3. Period: {months} months\n\nLandlord signature: ________\nTenant signature: ________\n',
  },
  'complaint': {
    'title': 'COMPLAINT / APPLICATION (DRAFT)',
    'fields': ['name|Aapka naam', 'authority|Kis authority ko', 'address|Aapka address',
      'subject|Subject', 'facts|Pura mamla', 'relief|Aap kya chahte hain'],
    'body': 'To,\n{authority}\n\nSubject: {subject}\n\nRespected Sir/Madam,\n\n'
        'Main {name}, {address}, nivaasi hoon. Mera nivedan:\n\n{facts}\n\nMera nivedan hai ki: {relief}\n\n'
        'Kripya tatkaal karyavahi karein.\n\nDhanyavad,\n{name}\nDate: {date}\n',
  },
};

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final tts = FlutterTts();
  final stt = SpeechToText();
  final ctrl = TextEditingController();
  final logs = <String>[];
  bool listening = false;
  String? lastPdf;

  @override
  void initState() {
    super.initState();
    tts.setLanguage('hi-IN');
    speak('वापसी पर आपका स्वागत है, मालिक। मैं तैयार हूँ।');
  }

  Future<void> speak(String t) async {
    setState(() => logs.add('Jarvis: $t'));
    await tts.speak(t);
  }

  Future<void> openUrl(String u) =>
      launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);

  Future<void> listen() async {
    if (listening) {
      await stt.stop();
      setState(() => listening = false);
      return;
    }
    final ok = await stt.initialize();
    if (!ok) {
      speak('Mic permission nahi mili.');
      return;
    }
    setState(() => listening = true);
    await stt.listen(
      localeId: 'hi_IN',
      onResult: (r) {
        if (r.finalResult) {
          setState(() => listening = false);
          handle(r.recognizedWords);
        }
      },
    );
  }

  Future<Map<String, String>?> askFields(String title, List<String> fields) async {
    final cs = {for (final f in fields) f.split('|')[0]: TextEditingController()};
    return showDialog<Map<String, String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(children: [
            for (final f in fields)
              TextField(controller: cs[f.split('|')[0]], decoration: InputDecoration(labelText: f.split('|')[1])),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, {for (final e in cs.entries) e.key: e.value.text.trim()}),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> createDraft(String name) async {
    final tpl = drafts[name]!;
    final vals = await askFields(tpl['title'] as String, List<String>.from(tpl['fields'] as List));
    if (vals == null) return;
    final d = DateTime.now();
    vals['date'] = '${d.day}-${d.month}-${d.year}';
    var body = tpl['body'] as String;
    vals.forEach((k, v) => body = body.replaceAll('{$k}', v));
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(build: (c) => [
          pw.Text(tpl['title'] as String, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 12),
          pw.Text(body),
        ]));
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/${name.replaceAll(' ', '_')}_${d.millisecondsSinceEpoch}.pdf');
    await f.writeAsBytes(await doc.save());
    lastPdf = f.path;
    speak('$name ka draft PDF ban gaya. Whatsapp par bhejne ke liye bolo: jarvis whatsapp par bhejo.');
  }

  Future<Map<String, String>> cfg() async {
    final p = await SharedPreferences.getInstance();
    return {
      'name': p.getString('name') ?? '',
      'base': p.getString('base') ?? '',
      'model': p.getString('model') ?? '',
      'key': p.getString('key') ?? '',
    };
  }

  Future<void> settings() async {
    final c = await cfg();
    String sel = providers.containsKey(c['name']) ? c['name']! : 'Groq (free)';
    final base = TextEditingController(text: c['base']!.isEmpty ? providers[sel]![0] : c['base']);
    final model = TextEditingController(text: c['model']!.isEmpty ? providers[sel]![1] : c['model']);
    final key = TextEditingController(text: c['key']);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('AI provider aur API key'),
          content: SingleChildScrollView(
            child: Column(children: [
              DropdownButton<String>(
                value: sel,
                isExpanded: true,
                items: [for (final k in providers.keys) DropdownMenuItem(value: k, child: Text(k))],
                onChanged: (v) => set(() {
                  sel = v!;
                  base.text = providers[sel]![0];
                  model.text = providers[sel]![1];
                }),
              ),
              TextField(controller: base, decoration: const InputDecoration(labelText: 'Base URL')),
              TextField(controller: model, decoration: const InputDecoration(labelText: 'Model')),
              TextField(controller: key, obscureText: true, decoration: const InputDecoration(labelText: 'API key')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                final p = await SharedPreferences.getInstance();
                await p.setString('name', sel);
                await p.setString('base', base.text.trim());
                await p.setString('model', model.text.trim());
                await p.setString('key', key.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
                speak('Setting save ho gayi.');
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> askAi(String q) async {
    final c = await cfg();
    if (c['key']!.isEmpty || c['base']!.isEmpty) {
      speak('AI ke liye pehle upar settings me provider aur API key set karo.');
      return;
    }
    try {
      final r = await http
          .post(Uri.parse('${c['base']!.replaceAll(RegExp(r'/+$'), '')}/chat/completions'),
              headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${c['key']}'},
              body: jsonEncode({
                'model': c['model'],
                'temperature': 0.6,
                'max_tokens': 1024,
                'messages': [
                  {'role': 'system', 'content': systemPrompt},
                  {'role': 'user', 'content': q},
                ],
              }))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        speak('AI error ${r.statusCode}. API key ya limit check karo.');
        return;
      }
      final data = jsonDecode(utf8.decode(r.bodyBytes));
      speak((data['choices'][0]['message']['content'] as String).trim());
    } catch (e) {
      speak('Internet ya provider me dikkat hai.');
    }
  }

  Future<void> handle(String raw) async {
    if (raw.trim().isEmpty) return;
    setState(() => logs.add('Aap: $raw'));
    final text = normalize(raw).replaceAll('jarvis', '').trim();
    final prefs = await SharedPreferences.getInstance();
    bool has(List<String> w) => w.any((x) => text.contains(x));

    if (text.isEmpty) return speak('Ji malik, boliye.');
    if (has(['kaise ho', 'how are you'])) return speak('Main bilkul theek hoon, malik. Kya madad karoon?');
    if (has(['tum kaun ho', 'who are you'])) return speak('Main Jarvis hoon, aapka voice assistant.');
    if (has(['shukriya', 'dhanyavad', 'thank'])) return speak('Aapka swagat hai, malik.');
    if (RegExp(r'^(hello|hi|hey|namaste)\b').hasMatch(text)) {
      return speak('Namaste malik! Aap kya karwana chahte ho?');
    }
    if (has(['judgment'])) {
      if (has(['banao', 'bana', 'likho', 'create', 'generate'])) {
        return speak('Judgment sirf court deti hai. Main asli judgment Indian Kanoon par dhoondh sakta hoon.');
      }
      final q = removeWords(text, ['judgment', 'search', 'karo', 'dhoondo', 'law']);
      await openUrl('https://indiankanoon.org/search/?formInput=${Uri.encodeComponent(q.isEmpty ? 'judgment' : q)}');
      return speak('Indian Kanoon par judgment search kar diya.');
    }
    if (text.contains('whatsapp') && has(['bhej', 'send'])) {
      if (lastPdf != null && File(lastPdf!).existsSync()) {
        await Share.shareXFiles([XFile(lastPdf!)], text: 'Namaste, yeh draft PDF hai.');
        return speak('Share menu khul gaya, WhatsApp chuno.');
      }
      return speak('Pehle draft banao, phir bhejo.');
    }
    if (has(['draft', 'banao', 'bana'])) {
      if (has(['legal notice', 'notice'])) return createDraft('legal notice');
      if (has(['rent', 'kiraya'])) return createDraft('rent agreement');
      if (has(['complaint', 'shikayat', 'application'])) return createDraft('complaint');
      return speak('Kaunsa draft? Legal notice, rent agreement, ya complaint.');
    }
    if (has(['law', 'kanoon', 'section'])) {
      final q = removeWords(text, ['law', 'kanoon', 'search', 'karo', 'batao', 'kya', 'hai', 'ke', 'bare', 'mein', 'ka', 'ki']);
      if (q.isEmpty) return speak('Kaunsa kanoon ya section dhoondhna hai?');
      await openUrl('https://indiankanoon.org/search/?formInput=${Uri.encodeComponent(q)}');
      return speak('Indian Kanoon par $q search kar diya.');
    }
    if (text.contains('youtube') && has(['search', 'channel'])) {
      final q = removeWords(text, ['youtube', 'par', 'pe', 'search', 'karo', 'kar', 'do', 'channel', 'khol', 'open']);
      if (q.isEmpty) return speak('Kaunsa channel search karna hai?');
      await openUrl('https://www.youtube.com/results?search_query=${Uri.encodeComponent(q)}&sp=EgIQAg%3D%3D');
      return speak('YouTube par $q channel search kar diya.');
    }
    if (has(['coding', 'code', 'python'])) {
      final q = removeWords(text, ['coding', 'code', 'karo', 'batao', 'kaise', 'python', 'ke', 'bare', 'mein']);
      await openUrl('https://www.google.com/search?q=${Uri.encodeComponent('${q.isEmpty ? 'python programming' : q} python code')}');
      return speak('Coding search kar diya.');
    }
    const sites = {
      'youtube': 'https://www.youtube.com', 'google': 'https://www.google.com',
      'gmail': 'https://mail.google.com', 'whatsapp': 'https://web.whatsapp.com',
      'instagram': 'https://www.instagram.com', 'facebook': 'https://www.facebook.com',
    };
    if (has(['open', 'khol', 'chalao'])) {
      for (final e in sites.entries) {
        if (text.contains(e.key)) {
          await openUrl(e.value);
          return speak('${e.key} khol diya.');
        }
      }
    }
    if (text.startsWith('note likho')) {
      final n = text.replaceFirst('note likho', '').trim();
      if (n.isEmpty) return speak('Kya note likhna hai?');
      final l = prefs.getStringList('notes') ?? [];
      l.add('[${DateTime.now().toString().substring(0, 16)}] $n');
      await prefs.setStringList('notes', l);
      return speak('Note add ho gaya.');
    }
    if (text.startsWith('note padho')) {
      final l = prefs.getStringList('notes') ?? [];
      return speak(l.isEmpty ? 'Koi note nahi hai.' : l.join('. '));
    }
    if (has(['note saaf', 'clear notes'])) {
      await prefs.remove('notes');
      return speak('Saare notes saaf kar diye.');
    }
    if (has(['time', 'samay'])) {
      final n = DateTime.now();
      return speak('Abhi ${n.hour}:${n.minute.toString().padLeft(2, '0')} baje hain.');
    }
    if (has(['date', 'tarikh'])) {
      final n = DateTime.now();
      return speak('Aaj ki date ${n.day}-${n.month}-${n.year} hai.');
    }
    await askAi(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jarvis'), actions: [
        IconButton(icon: const Icon(Icons.settings), onPressed: settings),
      ]),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [for (final l in logs) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(l))],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(child: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Type karo...'))),
            IconButton(
                icon: const Icon(Icons.send),
                onPressed: () {
                  final t = ctrl.text;
                  ctrl.clear();
                  handle(t);
                }),
          ]),
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: listen,
        child: Icon(listening ? Icons.stop : Icons.mic),
      ),
    );
  }
}
