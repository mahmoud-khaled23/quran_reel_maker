package com.example.quran_reel_maker.alignment;

import ai.onnxruntime.*;
import org.json.*;
import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.CancellationException;

/** CPU CTC inference + canonical-text forced alignment. No Android or network API.
 * This same class is executed by the desktop parity/performance harness.
 */
public final class QuranAligner implements AutoCloseable {
    public static final String MODEL = "quran-ctc-q4-v1";
    public static final String REVISION = "f90650aac5d9dcff15230a19998c0027f45b33f1";
    public static final String QURAN_SHA = "6933e133dd56db778c801bf738848454e43648105a151e8d84d86a7cae39ec5f";
    public static final String MODEL_SHA = "9b17e04fdc2aef54720e62216a7c7ae7f55d27911ee7cd55253baa231845a587";
    public static final long MODEL_BYTES = 241230289L;
    public interface Progress { void update(double value, String message); }
    public static final class Cancellation {
        private boolean cancelled;
        private String reason = "Alignment cancelled. Existing timings were kept.";
        private OrtSession.RunOptions active;
        public synchronized void cancel() { cancel("Alignment cancelled. Existing timings were kept."); }
        public synchronized void cancel(String message) {
            if (!cancelled) reason = message;
            cancelled = true;
            if (active != null) try { active.setTerminate(true); } catch (OrtException ignored) { }
        }
        public synchronized void check() {
            if (cancelled) throw new CancellationException(reason);
        }
        synchronized void attach(OrtSession.RunOptions options) { check(); active = options; }
        synchronized void detach() { active = null; }
    }
    private final OrtEnvironment environment = OrtEnvironment.getEnvironment();
    private final OrtSession session;
    private final Map<String, String> verses = new HashMap<>();
    private final List<String> labels;
    private final int[] foldedClass = new int[56];
    public final double loadMillis;

    public QuranAligner(File model, byte[] quran, byte[] vocabBytes, Cancellation cancellation) throws Exception {
        long begin = System.nanoTime();
        check(model.length() == MODEL_BYTES && hash(model, cancellation).equals(MODEL_SHA),
            "Model missing or corrupt. Open Alignment model and download/repair the verified model.");
        check(hex(MessageDigest.getInstance("SHA-256").digest(quran)).equals(QURAN_SHA), "Quran asset differs. Reinstall the app.");
        check(hex(MessageDigest.getInstance("SHA-256").digest(vocabBytes)).equals("60b9e6174798b6e1a92c92fb5935e32522aebaca4cdd1f481fd220346471644c"), "Vocabulary differs. Reinstall the app.");
        for (String line : new String(quran, StandardCharsets.UTF_8).split("\n")) {
            if (!line.isEmpty() && !line.startsWith("#")) {
                String[] fields = line.split("\\|", 3);
                verses.put(fields[0] + ":" + fields[1], fields[2].trim());
            }
        }
        JSONObject vocab = new JSONObject(new String(vocabBytes, StandardCharsets.UTF_8));
        TreeSet<String> chars = new TreeSet<>();
        Iterator<String> keys = vocab.keys();
        while (keys.hasNext()) { String s = keys.next(); chars.add(s.length() == 1 ? character(s.charAt(0)) : ""); }
        chars.remove(""); labels = new ArrayList<>(); labels.add(""); labels.addAll(chars);
        keys = vocab.keys();
        while (keys.hasNext()) { String s = keys.next(); foldedClass[vocab.getInt(s)] = labels.indexOf(s.length() == 1 ? character(s.charAt(0)) : ""); }
        cancellation.check();
        try (OrtSession.SessionOptions options = new OrtSession.SessionOptions()) {
            options.setIntraOpNumThreads(2); options.setInterOpNumThreads(1);
            // Dynamic audio lengths otherwise retain large CPU arena allocations.
            options.setCPUArenaAllocator(false);
            options.setMemoryPatternOptimization(false);
            session = environment.createSession(model.getAbsolutePath(), options);
        }
        if (!session.getInputNames().equals(Collections.singleton("input_values"))) {
            session.close(); throw new IllegalArgumentException("Unexpected model inputs. Reinstall the model.");
        }
        loadMillis = (System.nanoTime() - begin) / 1e6;
    }

    public static void check(boolean ok, String message) { if (!ok) throw new IllegalArgumentException(message); }
    public static String hash(File file, Cancellation cancellation) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[262144]; int n;
            while ((n = in.read(buffer)) != -1) { cancellation.check(); digest.update(buffer, 0, n); }
        }
        return hex(digest.digest());
    }
    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte b : bytes) out.append(String.format(Locale.ROOT, "%02x", b & 255));
        return out.toString();
    }
    public static String character(char c) {
        if ("ٱأإآٰ".indexOf(c) >= 0) return "ا";
        if ("ىۦ".indexOf(c) >= 0) return "ي";
        if (c == 'ۥ') return "و";
        if (c == '|' || Character.isWhitespace(c)) return "|";
        int type = Character.getType(c);
        if (c == 'ـ' || c == '-' || type == Character.NON_SPACING_MARK || type == Character.COMBINING_SPACING_MARK || type == Character.ENCLOSING_MARK) return "";
        return c >= '\u0621' && c <= '\u064a' ? String.valueOf(c) : "";
    }
    private float[] readAudio(File pcm, double duration, Cancellation cancellation) throws IOException {
        check(pcm.length() % 4 == 0 && pcm.length() >= 32000 && pcm.length() <= 180L * 16000 * 4 + 6400,
            "Invalid decoded audio. Select 0.5–180 seconds of audible recitation.");
        check(Math.abs(pcm.length() / 64000.0 - duration) <= .1, "Trim exceeds readable audio. Reimport or shorten it.");
        float[] audio = new float[(int) (pcm.length() / 4)]; double energy = 0;
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(new FileInputStream(pcm)))) {
            for (int i = 0; i < audio.length; i++) {
                if (i % 16000 == 0) cancellation.check();
                audio[i] = Float.intBitsToFloat(Integer.reverseBytes(in.readInt()));
                check(Float.isFinite(audio[i]), "Non-finite audio samples. Convert the source to WAV.");
                energy += audio[i] * (double) audio[i];
            }
        }
        check(Math.sqrt(energy / audio.length) >= .0001, "No usable audio detected. Select audible recitation or use manual timing.");
        return audio;
    }

    public JSONObject align(JSONObject request, File pcm, Cancellation cancellation, Progress progress) throws Exception {
        long begin = System.nanoTime();
        check(request.getInt("protocol") == 1 && QURAN_SHA.equals(request.getString("quranSha256")), "App/model protocol differs. Reinstall the app.");
        double offset = request.getDouble("trimStart"), end = request.getDouble("trimEnd"), duration = end - offset;
        check(Double.isFinite(offset) && Double.isFinite(end) && offset >= 0 && duration >= .5 && duration <= 180, "Select 0.5–180 seconds of matching audio.");
        int surah = request.getInt("surah"), first = request.getInt("firstAyah"), last = request.getInt("lastAyah");
        check(surah >= 1 && surah <= 114 && first >= 1 && last >= first && last <= 286, "Invalid ayah selection.");
        ArrayList<Integer> targetList = new ArrayList<>(), owners = new ArrayList<>();
        ArrayList<int[]> words = new ArrayList<>(); JSONArray cues = new JSONArray();
        for (int ayah = first; ayah <= last; ayah++) {
            String verse = verses.get(surah + ":" + ayah); check(verse != null, "Ayah missing in canonical Quran.");
            String[] originals = verse.split("\\s+");
            int low = ayah == first ? request.optInt("firstWord", 0) : 0;
            int high = ayah == last ? request.optInt("lastWord", originals.length - 1) : originals.length - 1;
            check(low >= 0 && high >= low && high < originals.length, "Invalid partial-ayah word range.");
            cues.put(new JSONObject().put("surah", surah).put("ayah", ayah).put("firstWord", low).put("lastWord", high)
                .put("timingSource", "automatic").put("alignmentModel", MODEL).put("words", new JSONArray()).put("warnings", new JSONArray()));
            for (int w = low; w <= high; w++) {
                ArrayList<Integer> letters = new ArrayList<>();
                for (char c : originals[w].toCharArray()) {
                    String s = character(c); if (s.isEmpty() || s.equals("|")) continue;
                    int index = labels.indexOf(s); check(index > 0, "Unsupported acoustic character. Use manual timing."); letters.add(index);
                }
                if (letters.isEmpty()) continue;
                if (!targetList.isEmpty()) { targetList.add(labels.indexOf("|")); owners.add(-1); }
                for (int letter : letters) { targetList.add(letter); owners.add(words.size()); }
                words.add(new int[] {ayah - first, w});
            }
        }
        int[] target = new int[targetList.size()]; for (int i = 0; i < target.length; i++) target[i] = targetList.get(i);
        check(target.length > 0 && (duration * 50) * (2 * target.length + 1) <= 40000000L, "Too much text for memory limit. Select fewer ayahs and shorter audio.");
        float[] audio = readAudio(pcm, duration, cancellation);
        List<double[]> rows = new ArrayList<>(); List<Double> clocks = new ArrayList<>();
        long inferenceStart = System.nanoTime();
        for (int start = 0; start < audio.length; start += 15 * 16000) {
            cancellation.check();
            int low = Math.max(0, start - 16000), high = Math.min(audio.length, start + 16 * 16000);
            float[] wave = Arrays.copyOfRange(audio, low, high); double mean = 0, variance = 0;
            for (float x : wave) mean += x; mean /= wave.length;
            for (float x : wave) variance += (x - mean) * (x - mean); variance = Math.sqrt(variance / wave.length + 1e-7);
            for (int i = 0; i < wave.length; i++) wave[i] = (float) ((wave[i] - mean) / variance);
            try (OnnxTensor input = OnnxTensor.createTensor(environment, FloatBuffer.wrap(wave), new long[] {1, wave.length});
                 OrtSession.RunOptions run = new OrtSession.RunOptions()) {
                cancellation.attach(run);
                try (OrtSession.Result output = session.run(Collections.singletonMap("input_values", input), run)) {
                    float[][] logits = ((float[][][]) output.get(0).getValue())[0];
                    for (int t = 0; t < logits.length; t++) {
                        double clock = (t * 320 + 200 + low) / 16000.0;
                        if (clock < start / 16000.0 || clock >= Math.min(start / 16000.0 + 15, audio.length / 16000.0)) continue;
                        check(logits[t].length == 56, "Model output shape differs.");
                        double max = -Double.MAX_VALUE, total = 0; double[] probabilities = new double[56], row = new double[labels.size()];
                        for (float x : logits[t]) { check(Float.isFinite(x), "Invalid model output."); max = Math.max(max, x); }
                        for (int k = 0; k < 56; k++) { probabilities[k] = Math.exp(logits[t][k] - max); total += probabilities[k]; }
                        for (int k = 0; k < 56; k++) row[foldedClass[k]] += probabilities[k] / total;
                        for (int k = 0; k < row.length; k++) row[k] = Math.log(Math.max(row[k], 1e-30));
                        rows.add(row); clocks.add(clock);
                    }
                } finally { cancellation.detach(); }
            }
            progress.update(.1 + .75 * Math.min(start + 15 * 16000.0, audio.length) / audio.length, "Listening locally on CPU…");
        }
        double inferenceMillis = (System.nanoTime() - inferenceStart) / 1e6;
        cancellation.check(); progress.update(.9, "Aligning canonical words and checking boundaries…");
        double[][] logp = rows.toArray(new double[0][]);
        ArrayList<Integer> recognized = new ArrayList<>(), lexical = new ArrayList<>(); int previous = -1, space = labels.indexOf("|");
        for (double[] row : logp) {
            int best = 0; for (int k = 1; k < row.length; k++) if (row[k] > row[best]) best = k;
            if (best != previous && best != 0 && best != space) recognized.add(best); previous = best;
        }
        for (int t : target) if (t != space) lexical.add(t);
        double mismatch = editDistance(lexical, recognized) / (double) Math.max(1, lexical.size());
        check(mismatch <= .65, "Audio does not match the selected words reliably. Check surah/range, crop introductions or repetitions, reduce noise, or use manual timings.");
        int[] path = viterbi(logp, target, cancellation);
        int[] wordFirst = new int[words.size()], wordLast = new int[words.size()], counts = new int[words.size()];
        double[] sums = new double[words.size()]; Arrays.fill(wordFirst, -1);
        for (int t = 0; t < path.length; t++) if (path[t] % 2 == 1) {
            int token = (path[t] - 1) / 2, w = owners.get(token); if (w < 0) continue;
            if (wordFirst[w] < 0) wordFirst[w] = t; wordLast[w] = t; counts[w]++; sums[w] += logp[t][target[token]];
        }
        for (int w = 0; w < words.size(); w++) {
            check(wordFirst[w] >= 0, "A word could not be located. Check selection or use manual timing.");
            double start = Math.max(0, clocks.get(wordFirst[w]) - .01) + offset;
            double stop = Math.min(duration, clocks.get(wordLast[w]) + .01) + offset;
            double score = Math.exp(sums[w] / counts[w]); JSONObject cue = cues.getJSONObject(words.get(w)[0]);
            cue.getJSONArray("words").put(new JSONObject().put("index", words.get(w)[1]).put("start", start).put("end", stop).put("score", score));
            if (score < .35 || stop - start < .08) warn(cue, "Uncertain word boundary; listen and adjust.");
            if (stop - start > 4) warn(cue, "Long word/elongation or internal pause; verify the boundary.");
        }
        double meanScore = 0;
        for (int i = 0; i < cues.length(); i++) {
            JSONObject cue = cues.getJSONObject(i); JSONArray ws = cue.getJSONArray("words");
            check(ws.length() > 0, "Selection contains no spoken words. Change the boundary words.");
            double score = 0;
            for (int w = 0; w < ws.length(); w++) {
                score += ws.getJSONObject(w).getDouble("score");
                if (w > 0 && ws.getJSONObject(w).getDouble("start") - ws.getJSONObject(w - 1).getDouble("end") > 1.5) warn(cue, "Long internal pause; check for repeated phrases.");
            }
            score /= ws.length(); meanScore += score;
            cue.put("start", ws.getJSONObject(0).getDouble("start")).put("end", ws.getJSONObject(ws.length() - 1).getDouble("end")).put("alignmentScore", score);
            warn(cue, "Automatic draft: listen to every boundary before export. Acoustic scores are not accuracy probabilities.");
            warn(cue, "Repeated phrases are not separately segmented; crop them out or correct timings manually.");
            warn(cue, "Android candidate: word accuracy and resource targets await physical-device and independently annotated evaluation.");
            if (mismatch > .2) warn(cue, "Possible repeated/omitted words, vocalization differences or background noise. Check the entire selection.");
        }
        if (cues.getJSONObject(0).getDouble("start") - offset < .15 || end - cues.getJSONObject(cues.length() - 1).getDouble("end") < .15)
            warn(cues.getJSONObject(0), "Speech touches a trim edge. Include the complete first/last word before rerunning.");
        check(meanScore / cues.length() >= .15, "Acoustic alignment is too uncertain. Try cleaner audio or a shorter selection; manual timing remains available.");
        cancellation.check();
        return new JSONObject().put("protocol", 1).put("type", "result").put("timeline", "source").put("model", MODEL).put("revision", REVISION)
            .put("quranSha256", QURAN_SHA).put("mismatchRatio", mismatch).put("cues", cues)
            .put("metrics", new JSONObject().put("loadMs", loadMillis).put("inferenceMs", inferenceMillis).put("alignMs", (System.nanoTime() - begin) / 1e6).put("audioSeconds", duration).put("threads", 2).put("cpuArena", false).put("memoryPattern", false));
    }
    private static void warn(JSONObject cue, String text) throws JSONException {
        JSONArray warnings = cue.getJSONArray("warnings");
        for (int i = 0; i < warnings.length(); i++) if (text.equals(warnings.getString(i))) return;
        warnings.put(text);
    }
    public static int editDistance(List<Integer> a, List<Integer> b) {
        int[] previous = new int[b.size() + 1]; for (int j = 0; j <= b.size(); j++) previous[j] = j;
        for (int i = 0; i < a.size(); i++) {
            int[] current = new int[b.size() + 1]; current[0] = i + 1;
            for (int j = 0; j < b.size(); j++) current[j + 1] = Math.min(Math.min(current[j] + 1, previous[j + 1] + 1), previous[j] + (a.get(i).equals(b.get(j)) ? 0 : 1));
            previous = current;
        }
        return previous[b.size()];
    }
    public static int[] viterbi(double[][] logp, int[] target, Cancellation cancellation) {
        int frames = logp.length, count = target.length * 2 + 1;
        check(target.length > 0 && frames >= target.length && (long) frames * count <= 40000000L, "Audio/text exceeds alignment memory limit or is too short.");
        int[] states = new int[count]; for (int i = 0; i < target.length; i++) states[2 * i + 1] = target[i];
        double[] prev = new double[count]; Arrays.fill(prev, Double.NEGATIVE_INFINITY); prev[0] = logp[0][0]; prev[1] = logp[0][target[0]];
        byte[] trace = new byte[frames * count];
        for (int t = 1; t < frames; t++) {
            cancellation.check(); double[] current = new double[count];
            for (int s = 0; s < count; s++) {
                double best = prev[s]; byte move = 0;
                if (s > 0 && prev[s - 1] > best) { best = prev[s - 1]; move = 1; }
                if (s > 1 && states[s] != 0 && states[s] != states[s - 2] && prev[s - 2] > best) { best = prev[s - 2]; move = 2; }
                trace[t * count + s] = move; current[s] = best + logp[t][states[s]];
            }
            prev = current;
        }
        int state = prev[count - 1] >= prev[count - 2] ? count - 1 : count - 2;
        check(Double.isFinite(prev[state]), "No complete alignment path. Check selected words or use manual timing.");
        int[] path = new int[frames];
        for (int t = frames - 1; t >= 0; t--) { path[t] = state; state -= trace[t * count + state]; }
        return path;
    }
    @Override public void close() throws OrtException { session.close(); }
}
