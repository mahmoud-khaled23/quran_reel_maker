import com.example.quran_reel_maker.alignment.QuranAligner;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import org.json.*;

/** Desktop execution of the actual Android Java core. Never an Android benchmark. */
public final class NativeHarness {
    static void require(boolean value) { if (!value) throw new AssertionError(); }
    static void unitTests() {
        QuranAligner.Cancellation c = new QuranAligner.Cancellation();
        double x = -100;
        int[] path = QuranAligner.viterbi(new double[][] {{x,0},{0,x},{x,0}}, new int[]{1,1}, c);
        require(Arrays.equals(path, new int[]{1,2,3}));
        try { QuranAligner.viterbi(new double[][] {{x,0},{x,0}}, new int[]{1,1}, c); throw new AssertionError(); }
        catch (IllegalArgumentException expected) { }
        c.cancel();
        try { QuranAligner.viterbi(new double[][] {{x,0},{x,0}}, new int[]{1}, c); throw new AssertionError(); }
        catch (java.util.concurrent.CancellationException expected) { }
        require(QuranAligner.character('ٱ').equals("ا"));
        require(QuranAligner.character('ٰ').equals("ا"));
        require(QuranAligner.character('ۖ').isEmpty());
        require(QuranAligner.editDistance(Arrays.asList(1,2,1), Arrays.asList(1,1)) == 1);
        System.err.println("Native core algorithm tests passed (CTC repeats, impossible path, cancellation, normalization, edit distance).");
    }
    public static void main(String[] args) throws Exception {
        unitTests(); if (args.length == 0) return;
        QuranAligner.Cancellation token = new QuranAligner.Cancellation();
        JSONObject report = new JSONObject().put("platform", "desktop-jvm-" + System.getProperty("os.name") + "-" + System.getProperty("os.arch")).put("java", System.getProperty("java.version"));
        long begin = System.nanoTime();
        try (QuranAligner aligner = new QuranAligner(new File(args[0]), Files.readAllBytes(Path.of(args[1])), Files.readAllBytes(Path.of(args[2])), token)) {
            JSONObject request = new JSONObject(Files.readString(Path.of(args[3]))); JSONArray runs = new JSONArray();
            for (int i = 0; i < Integer.parseInt(args[5]); i++) {
                long start = System.nanoTime();
                try {
                    JSONObject result = aligner.align(request, new File(args[4]), token, (value, message) -> {});
                    runs.put(new JSONObject().put("status", "aligned").put("elapsedMs", (System.nanoTime() - start) / 1e6).put("result", result));
                } catch (IllegalArgumentException error) {
                    runs.put(new JSONObject().put("status", "rejected").put("elapsedMs", (System.nanoTime() - start) / 1e6).put("error", error.getMessage()));
                }
            }
            report.put("loadMs", aligner.loadMillis).put("runs", runs);
        }
        report.put("processWorkMs", (System.nanoTime() - begin) / 1e6);
        Files.writeString(Path.of(args[6]), report.toString(2) + "\n");
    }
}
