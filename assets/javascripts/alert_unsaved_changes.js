var warnMessage = "You have unsaved changes!";

$(document).ready(function () {	
	
		$('#wktime_edit input:not(:submit), #wktime_edit select, #comment-dlg textarea, #comment-dlg select, .ui-dialog textarea, .ui-dialog select').change(function()  { 
			//triggers change in all input fields including text type
			// #comment-dlg textarea, #comment-dlg select are the spectific fields in the popup showComment
    		window.onbeforeunload = function () {
    			 if (warnMessage != null) return warnMessage;
    		}
		});
		$('input:submit').click(function(e) {
			warnMessage = null;
		});
});

