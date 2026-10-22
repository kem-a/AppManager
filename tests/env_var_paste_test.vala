using AppManager.Core;

private void test_appimage_assignment() {
    var assignments = EnvVarPaste.parse("QT_QPA_PLATFORM=xcb");
    assert_cmpint(assignments.length, CompareOperator.EQ, 1);
    assert_cmpstr(assignments[0].name, CompareOperator.EQ, "QT_QPA_PLATFORM");
    assert_cmpstr(assignments[0].value, CompareOperator.EQ, "xcb");
}

private void test_multiline_instructions() {
    var assignments = EnvVarPaste.parse("  # launch settings\r\n\nexport QT_QPA_PLATFORM = xcb\r\nnot an assignment\n=1\nLIBGL_ALWAYS_SOFTWARE=1\n");
    assert_cmpint(assignments.length, CompareOperator.EQ, 2);
    assert_cmpstr(assignments[0].name, CompareOperator.EQ, "QT_QPA_PLATFORM");
    assert_cmpstr(assignments[0].value, CompareOperator.EQ, "xcb");
    assert_cmpstr(assignments[1].name, CompareOperator.EQ, "LIBGL_ALWAYS_SOFTWARE");
    assert_cmpstr(assignments[1].value, CompareOperator.EQ, "1");
}

private void test_quoted_paths_and_literal_values() {
    var assignments = EnvVarPaste.parse("APP_CONFIG_DIR=\"/home/alex/My App/config\"\nAPP_DATA_DIR='  /home/alex/My Files  '\nHTTP_PROXY=http://localhost:8080/?mode=direct\nEMPTY=\nPADDED= value \nUNMATCHED=\"value\nTRAILING=\"value\" \nLITERAL='$HOME/config # literal'");
    assert_cmpint(assignments.length, CompareOperator.EQ, 8);
    assert_cmpstr(assignments[0].value, CompareOperator.EQ, "/home/alex/My App/config");
    assert_cmpstr(assignments[1].value, CompareOperator.EQ, "  /home/alex/My Files  ");
    assert_cmpstr(assignments[2].value, CompareOperator.EQ, "http://localhost:8080/?mode=direct");
    assert_cmpstr(assignments[3].value, CompareOperator.EQ, "");
    assert_cmpstr(assignments[4].value, CompareOperator.EQ, "value ");
    assert_cmpstr(assignments[5].value, CompareOperator.EQ, "\"value");
    assert_cmpstr(assignments[6].value, CompareOperator.EQ, "\"value\" ");
    assert_cmpstr(assignments[7].value, CompareOperator.EQ, "$HOME/config # literal");
}

private void test_plain_text_and_empty_assignments() {
    assert_false(EnvVarPaste.looks_like_assignment("="));
    assert_false(EnvVarPaste.looks_like_assignment("QT_QPA_PLATFORM"));
    assert_false(EnvVarPaste.looks_like_assignment(""));
    assert_true(EnvVarPaste.looks_like_assignment("QT_QPA_PLATFORM=xcb"));
    assert_cmpint(EnvVarPaste.parse("just-a-name\n=1\nexport =2\n # IGNORE=1\n").length,
                  CompareOperator.EQ, 0);
}

int main(string[] args) {
    Test.init(ref args);
    Test.add_func("/env-var-paste/appimage-assignment", test_appimage_assignment);
    Test.add_func("/env-var-paste/multiline-instructions", test_multiline_instructions);
    Test.add_func("/env-var-paste/quoted-paths-and-literal-values", test_quoted_paths_and_literal_values);
    Test.add_func("/env-var-paste/plain-text-and-empty-assignments", test_plain_text_and_empty_assignments);
    return Test.run();
}
