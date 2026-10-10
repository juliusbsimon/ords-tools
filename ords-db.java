// Small database helper for ords-install.sh. It uses the Oracle JDBC driver
// that ships inside ords.war, so the server needs no SQL client.
//
//   printf '%s\n' "$PASSWORD" | java -cp ojdbc11.jar ords-db.java COMMAND HOST PORT SERVICE USER
//
// The password is read from the first line of standard input, never from the
// command line, where any user on the server could see it in the process list.
// USER may end in "AS SYSDBA" for SYS on a self-managed database.
//
// Commands:
//   check    print what the installer needs to know, as key=value lines
//   set-cdn  point APEX's static files at Oracle's CDN, for the APEX version
//            the database actually runs
//   unlock-apex-public
//            unlock APEX_PUBLIC_USER. ORDS reaches APEX by proxying through
//            it, and a locked account makes every APEX page fail with HTTP 570
//   set-ords-public-password
//            give ORDS_PUBLIC_USER a new password, read from the SECOND line of
//            standard input. 'ords install' does not do this when ORDS is
//            already in the database: it only stores the password it is given
//
// A value that could not be read (usually for lack of privileges) is printed
// empty rather than failing the whole check. Exit status: 0 done, 1 could not
// connect or the command failed, 2 bad usage.

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.Properties;

public class OrdsDb {
    static final String CDN_ROOT = "https://static.oracle.com/cdn/apex/";

    public static void main(String[] args) throws Exception {
        if (args.length != 5) {
            System.err.println("usage: ords-db.java check|set-cdn|unlock-apex-public|set-ords-public-password HOST PORT SERVICE USER  (password on stdin)");
            System.exit(2);
        }
        String command = args[0];
        String url = "jdbc:oracle:thin:@//" + args[1] + ":" + args[2] + "/" + args[3];
        String user = args[4].trim();
        BufferedReader stdin = new BufferedReader(new InputStreamReader(System.in));
        String password = stdin.readLine();

        Properties props = new Properties();
        String upper = user.toUpperCase().replaceAll("\\s+", " ");
        if (upper.endsWith(" AS SYSDBA")) {
            user = user.substring(0, upper.indexOf(" AS SYSDBA")).trim();
            props.put("internal_logon", "sysdba");
        }
        props.put("user", user);
        props.put("password", password == null ? "" : password);
        DriverManager.setLoginTimeout(20);

        try (Connection c = DriverManager.getConnection(url, props)) {
            switch (command) {
                case "check":   check(c); break;
                case "set-cdn": setCdn(c); break;
                case "unlock-apex-public": unlockApexPublic(c); break;
                case "set-ords-public-password": setOrdsPublicPassword(c, stdin.readLine()); break;
                default:
                    System.err.println("unknown command: " + command);
                    System.exit(2);
            }
        } catch (SQLException e) {
            System.out.println("error=" + oneLine(e.getMessage()));
            System.exit(1);
        }
    }

    static void check(Connection c) {
        System.out.println("login=ok");
        System.out.println("db_version=" + nz(query(c,
            "select version_full from product_component_version where product like 'Oracle%' and rownum = 1")));
        System.out.println("apex_version=" + nz(query(c, "select version_no from apex_release")));
        System.out.println("ords_schema=" + ("1".equals(query(c,
            "select count(*) from all_users where username = 'ORDS_METADATA'")) ? "yes" : "no"));
        System.out.println("ords_schema_version=" + nz(query(c, "select version from ords_metadata.ords_version")));
        System.out.println("ords_public_user=" + ("1".equals(query(c,
            "select count(*) from all_users where username = 'ORDS_PUBLIC_USER'")) ? "yes" : "no"));
        System.out.println("apex_public_user_status=" + nz(query(c,
            "select account_status from dba_users where username = 'APEX_PUBLIC_USER'")));
        System.out.println("image_prefix=" + nz(imagePrefix(c)));
    }

    // The same call Oracle's own reset_image_prefix_core.sql makes. Unlike that
    // script it needs no SYS, so it can work for the RDS master user.
    static void setCdn(Connection c) throws SQLException {
        String version = query(c, "select version_no from apex_release");
        if (version == null || version.isEmpty()) {
            throw new SQLException("APEX is not installed in this database (no apex_release).");
        }
        String target = CDN_ROOT + version + "/";
        try (CallableStatement s = c.prepareCall("begin apex_instance_admin.set_parameter('IMAGE_PREFIX', ?); commit; end;")) {
            s.setString(1, target);
            s.execute();
        }
        System.out.println("image_prefix=" + target);
    }

    static void unlockApexPublic(Connection c) throws SQLException {
        try (Statement s = c.createStatement()) {
            s.execute("alter user apex_public_user account unlock");
        }
        System.out.println("apex_public_user_status=" + nz(query(c,
            "select account_status from dba_users where username = 'APEX_PUBLIC_USER'")));
    }

    // DDL takes no bind variables, so the password goes into the statement. A
    // double quote would end the quoted identifier early, so it is refused.
    static void setOrdsPublicPassword(Connection c, String newPassword) throws SQLException {
        if (newPassword == null || newPassword.isEmpty()) {
            throw new SQLException("No new password on the second line of standard input.");
        }
        if (newPassword.contains("\"")) {
            throw new SQLException("The new password must not contain a double quote.");
        }
        try (Statement s = c.createStatement()) {
            s.execute("alter user ords_public_user identified by \"" + newPassword + "\" account unlock");
        }
        System.out.println("ords_public_user_password=set");
    }

    static String imagePrefix(Connection c) {
        try (CallableStatement s = c.prepareCall("begin ? := apex_instance_admin.get_parameter('IMAGE_PREFIX'); end;")) {
            s.registerOutParameter(1, Types.VARCHAR);
            s.execute();
            return s.getString(1);
        } catch (SQLException e) {
            return null;
        }
    }

    // One value, or null when the query fails - usually a missing privilege,
    // which the caller reports as "unknown" instead of stopping.
    static String query(Connection c, String sql) {
        try (Statement s = c.createStatement(); ResultSet r = s.executeQuery(sql)) {
            return r.next() ? r.getString(1) : "";
        } catch (SQLException e) {
            return null;
        }
    }

    static String nz(String s) { return s == null ? "" : s; }

    static String oneLine(String s) { return s == null ? "" : s.replaceAll("\\s+", " ").trim(); }
}
