/* ---------------------------------------------------------------------
   Настройки подключения. Файл лежит рядом с index.html и грузится первым.

   Правило: страница, открытая с localhost или 127.0.0.1 (Live Server в VS Code),
   работает с ТЕСТОВОЙ базой. Открытая с GitHub Pages — с БОЕВОЙ.
   Перепутать нельзя: в тестовом режиме в шапке горит красная плашка «ТЕСТ».

   Где взять url и key: Supabase → нужный проект → Settings → API →
   Project URL и publishable key. Ключ публичный по смыслу, прятать его не нужно:
   доступ к данным закрыт политиками RLS.
--------------------------------------------------------------------- */
(function () {
  var isLocal = location.hostname === 'localhost'
    || location.hostname === '127.0.0.1'
    || location.hostname === '';

  var PROD = {
    env: 'prod',
    url: 'https://crokwtmokshdankujdhx.supabase.co',
    key: 'sb_publishable_WBzL5wto5pGEiwbQFqxkSQ_dUOXxabB',
    /* Адрес, куда Supabase возвращает из письма. Пусто — берётся адрес текущей страницы.
       Этот адрес должен быть в Supabase → Authentication → URL Configuration. */
    returnUrl: ''
  };

  var DEV = {
    env: 'dev',
    url: 'https://ТЕСТОВЫЙ-ПРОЕКТ.supabase.co',
    key: 'sb_publishable_ТЕСТОВЫЙ_КЛЮЧ',
    returnUrl: 'http://localhost:5500/index.html'
  };

  window.APP_CONFIG = isLocal ? DEV : PROD;
  window.APP_RETURN_URL = window.APP_CONFIG.returnUrl || '';
})();
