function EngramClipPreprocessingJS() {}

EngramClipPreprocessingJS.prototype = {
    run: function(arguments) {
        let selection = "";
        if (window.getSelection) {
            selection = String(window.getSelection());
        }

        arguments.completionFunction({
            title: document.title || "",
            selection: selection,
            url: window.location ? window.location.href : ""
        });
    }
};

window.ExtensionPreprocessingJS = new EngramClipPreprocessingJS();
