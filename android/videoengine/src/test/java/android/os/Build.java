package android.os;

/**
 * A JVM stand-in for the framework class. The unit-test stub leaves every field null, and Media3's "am I running in a
 * test" check (which decides how strictly ParsableByteArray asserts) cannot take a null fingerprint.
 */
public class Build {
    public static final String FINGERPRINT = "robolectric";
    public static final String DEVICE = "jvm";
    public static final String MANUFACTURER = "jvm";
    public static final String MODEL = "jvm";
    public static final String HARDWARE = "jvm";
    public static final String PRODUCT = "jvm";

    public static class VERSION {
        public static final int SDK_INT = 34;
        public static final String RELEASE = "14";
    }
}
