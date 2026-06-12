(function(){
  var btn=[...document.querySelectorAll('button')].find(b=>b.textContent.trim()==='Skip');
  if(btn)btn.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
})();
