/// Every piece of text the person sees, in Mongolian.
///
/// Kept in one file so the wording can be reviewed and fixed in one place.
/// Rule: no user-facing string literals anywhere else in lib/ (test/strings_test.dart checks this).
/// Names are never given grammatical suffixes ("Батад"), because the suffix depends on the name;
/// sentences are built so the name stands alone ("Бат: …", "Та → Бат").
library;

abstract final class S {
  // ---------------------------------------------------------------- general
  static const appName = 'NetZero';
  static const cancel = 'Болих';
  static const save = 'Хадгалах';
  static const add = 'Нэмэх';
  static const create = 'Үүсгэх';
  static const tryAgain = 'Дахин оролдох';
  static const loading = 'Ачааллаж байна…';
  static const somethingWentWrong = 'Алдаа гарлаа. Дахин оролдоно уу.';
  static const noConnection = 'Интернэт холболт алга. Холболтоо шалгаад дахин оролдоно уу.';
  static const sessionExpired = 'Нэвтрэх хугацаа дууссан. Дахин нэвтэрнэ үү.';
  static String unexpectedResponse(int? status) => 'Серверээс тодорхойгүй хариу ирлээ ($status).';
  static const you = 'Та';
  static String youSuffix(String name) => '$name (та)';
  static const formerMember = 'Хуучин гишүүн';
  static const amount = 'Дүн';
  static const amountHint = 'Дүнгээ оруулна уу, жишээ нь 12.50';
  static const edit = 'Засах';
  static const delete = 'Устгах';
  static const ok = 'Ойлголоо';
  static const actionFailed = 'Амжилтгүй боллоо';
  static const discardChangesTitle = 'Өөрчлөлтөө хаях уу?';
  static const discardChangesBody = 'Хадгалаагүй өөрчлөлт устана.';
  static const discard = 'Хаях';
  static const keepEditing = 'Үргэлжлүүлэх';
  static const fileTooLarge = 'Зураг хэт том байна. 10 МБ хүртэл зураг оруулна уу.';
  static const uploadFailed = 'Зургийг байршуулж чадсангүй. Дахин оролдоно уу.';

  // Photos (image_picker errors)
  static const cameraPermissionDenied =
      'Камер ашиглах зөвшөөрөл алга. Утасныхаа Тохиргоо → NetZero хэсэгт орж камерыг зөвшөөрнө үү.';
  static const photosPermissionDenied =
      'Зургийн санд хандах зөвшөөрөл алга. Утасныхаа Тохиргоо → NetZero хэсэгт орж зургийн санг зөвшөөрнө үү.';
  static const noCamera = 'Энэ төхөөрөмжид камер алга. Зургийн сангаас сонгоно уу.';
  static const couldNotOpenCamera = 'Камерыг нээж чадсангүй. Дахин оролдоно уу.';
  static const couldNotOpenPhoto = 'Зургийг нээж чадсангүй. Өөр зураг сонгоно уу.';

  // ---------------------------------------------------------------- auth
  static const tagline = 'Хамтын зардлаа хувааж, тооцоогоо амархан хаа.';
  static const email = 'И-мэйл';
  static const password = 'Нууц үг';
  static const signIn = 'Нэвтрэх';
  static const newHere = 'Шинэ хэрэглэгч үү? Бүртгүүлэх';
  static const createAccount = 'Бүртгүүлэх';
  static const createAccountTitle = 'Бүртгэл үүсгэх';
  static const createAccountSubtitle = 'Найзууд тань энэ и-мэйлээр таныг бүлэгт нэмнэ.';
  static const yourName = 'Таны нэр';
  static const passwordHelper = 'Дор хаяж 10 тэмдэгт; жижиг үсэг, том үсэг, тоо орсон байх';
  static const enterValidEmail = 'Зөв и-мэйл хаяг оруулна уу';
  static const enterPassword = 'Нууц үгээ оруулна уу';
  static const enterName = 'Нэрээ оруулна уу';
  static const passwordTooShort = 'Дор хаяж 10 тэмдэгт байх ёстой';
  static const lowercaseLetter = 'жижиг үсэг';
  static const uppercaseLetter = 'том үсэг';
  static const aDigit = 'тоо';

  /// "Нууц үгэндээ том үсэг, тоо оруулна уу"
  static String passwordNeeds(List<String> missing) => 'Нууц үгэндээ ${missing.join(', ')} оруулна уу';
  static const checkEmailTitle = 'И-мэйлээ шалгана уу';
  static String enterCodeSentTo(String email) => '$email хаяг руу илгээсэн кодыг оруулна уу.';
  static const confirmationCode = 'Баталгаажуулах код';
  static const enterCode = 'И-мэйлээр ирсэн кодыг оруулна уу';
  static const confirmAndSignIn = 'Баталгаажуулаад нэвтрэх';
  static const resendCode = 'Код дахин илгээх';
  static String codeSent(String email) => '$email хаяг руу 6 оронтой код илгээлээ.';
  static String newCodeSent(String email) => '$email хаяг руу шинэ код илгээлээ.';
  static const codeResent = 'Илгээлээ. Ирсэн захидал болон спам хавтсаа шалгана уу.';

  // Forgot password
  static const forgotPassword = 'Нууц үгээ мартсан уу?';
  static const resetPasswordTitle = 'Нууц үг сэргээх';
  static const resetPasswordSubtitle = 'И-мэйл хаягаа оруулбал нууц үг солих код илгээнэ.';
  static const sendCode = 'Код илгээх';
  static const newPasswordTitle = 'Шинэ нууц үг';
  static String newPasswordSubtitle(String email) => '$email хаяг руу илгээсэн код болон шинэ нууц үгээ оруулна уу.';
  static const newPassword = 'Шинэ нууц үг';
  static const setPasswordAndSignIn = 'Нууц үг солиод нэвтрэх';
  static String resetCodeSent(String email) => '$email хаяг руу нууц үг солих код илгээлээ.';

  // Cognito errors
  static const wrongEmailOrPassword = 'И-мэйл эсвэл нууц үг буруу байна.';
  static const accountExists = 'Энэ и-мэйлээр бүртгэл аль хэдийн үүссэн байна.';
  static const passwordRules = 'Нууц үг дор хаяж 10 тэмдэгттэй, жижиг үсэг, том үсэг болон тоо агуулсан байх ёстой.';
  static const noAccountForEmail = 'Энэ и-мэйлээр бүртгэл олдсонгүй.';
  static const cannotResetUnverified = 'Энэ бүртгэлийн и-мэйл баталгаажаагүй тул нууц үгийг сэргээх боломжгүй.';
  static const resetCodeExpired = 'Кодын хугацаа дууссан. "$resendCode" дээр дарж шинэ код аваарай.';
  static const codeMismatch = 'Код буруу байна. И-мэйлээ шалгаад дахин оролдоно уу.';
  static const codeExpired = 'Кодын хугацаа дууссан. "$resendCode" дээр дарна уу.';
  static const tooManyAttempts = 'Хэт олон удаа оролдлоо. Түр хүлээгээд дахин оролдоно уу.';
  static const checkEmailForCode = 'И-мэйлээр ирсэн баталгаажуулах кодоо шалгана уу.';
  static const needsNewPassword = 'Энэ бүртгэлд шинэ нууц үг шаардлагатай. Админаар байнгын нууц үг тохируулуулна уу.';
  static const signInFailed = 'Нэвтрэхэд алдаа гарлаа. Дахин оролдоно уу.';

  // ---------------------------------------------------------------- groups
  static const signOut = 'Гарах';
  static const account = 'Миний бүртгэл';
  static const newGroup = 'Шинэ бүлэг';
  static const groupName = 'Нэр';
  static const groupNameHint = 'Байр, аялал, оройн хоол…';
  static const currency = 'Валют';
  static const giveGroupName = 'Бүлгийн нэрээ оруулна уу';
  static const couldNotCreateGroup = 'Бүлэг үүсгэж чадсангүй';
  static const noGroupsYet = 'Одоогоор бүлэг алга';
  static const noGroupsHint = 'Байр, аялал эсвэл оройн хоолонд зориулж бүлэг үүсгээд, хүмүүсээ и-мэйлээр нь уриарай.';
  static const groupNameTooLong = 'Нэр 80 тэмдэгтээс урт байж болохгүй';

  // Invites to me
  static const invitesTitle = 'Урилгууд';
  static String inviteMeta(String inviter, int members) => 'Урьсан: $inviter · $members гишүүн';
  static const accept = 'Нэгдэх';
  static const decline = 'Татгалзах';
  static const joinedGroup = 'Бүлэгт нэгдлээ';
  static const inviteDeclined = 'Урилгаас татгалзлаа';

  // ---------------------------------------------------------------- group detail
  static const inviteByEmail = 'И-мэйлээр урих';
  static const memberEmail = 'Гишүүний и-мэйл';
  static const inviteHelper = 'Тэр хүн энэ и-мэйлээр NetZero-д бүртгүүлж нэвтэрмэгц урилгаа харна.';
  static const invite = 'Урих';
  static String inviteSent(String email) => 'Урилга илгээлээ: $email';
  static const pendingInvites = 'Хүлээгдэж буй урилга';
  static const cancelInvite = 'Урилга цуцлах';
  static const members = 'Гишүүд';
  static const removeMember = 'Бүлгээс хасах';
  static String removeMemberQuestion(String name) => 'Энэ гишүүнийг бүлгээс хасах уу? ($name)';
  static const removeBlocked = 'Энэ гишүүний тооцоо тэглэгдээгүй байна. Эхлээд тооцоогоо хаана уу.';
  static const leaveGroup = 'Бүлгээс гарах';
  static const leaveGroupQuestion = 'Энэ бүлгээс гарах уу? Дахин нэгдэхэд урилга хэрэгтэй болно.';
  static const leaveBlocked = 'Таны тооцоо тэглэгдээгүй байна. Гарахын өмнө тооцоогоо хаана уу.';
  static const leftGroup = 'Бүлгээс гарлаа';
  static const renameGroup = 'Нэр солих';
  static const deleteGroup = 'Бүлэг устгах';
  static const deleteGroupQuestion = 'Энэ бүлгийг бүх гишүүнд нь устгах уу? Буцаах боломжгүй.';
  static const groupDeleted = 'Бүлэг устлаа';
  static const addExpense = 'Зардал нэмэх';
  static const couldNotLoadGroup = 'Бүлгийг ачаалж чадсангүй.';
  static const expenses = 'Зардлууд';
  static const noExpensesYet = 'Одоогоор зардал алга. Эхнийхээ зардлыг нэмээрэй.';
  static const loadMore = 'Цааш үзэх';
  static const couldNotRefresh = 'Шинэчилж чадсангүй';
  static const couldNotLoadMore = 'Цааш ачаалж чадсангүй';
  static const groupUnavailable = 'Бүлэг олдсонгүй';
  static const noLongerMember = 'Та энэ бүлгийн гишүүн байхаа больсон байна.';

  // Balance card
  static const yourBalance = 'Таны тооцоо';
  static const youGetBack = 'Та авах ёстой';
  static const youOwe = 'Та өгөх ёстой';
  static const allSquare = 'Тэнцүү';
  static const settled = 'тэнцүү';
  static const getsBack = 'авна';
  static const owes = 'өгнө';
  static const settleUp = 'Тооцоо хаах';
  static const paymentHistory = 'Төлбөрийн түүх';

  // Expense row
  static String paid(String payer, String amount) => '$payer $amount төлсөн';
  static const notInvolved = 'оролцоогүй';

  // ---------------------------------------------------------------- add expense
  static const description = 'Тайлбар';
  static const descriptionHint = 'Хүнс, такси, түрээс…';
  static const paidBy = 'Төлсөн';
  static const split = 'Хуваах';
  static const splitEven = 'Тэнцүү';
  static const splitExact = 'Дүнгээр';
  static const splitPercent = 'Хувиар';
  static const evenSplitNote =
      'Сервер дүнг хамгийн бага нэгж хүртэл хуваана. Илүү гарсан үлдэгдэл нэг хүнд, үргэлж ижил дүрмээр оногдоно.';
  static const enterTotalFirst = 'Эхлээд нийт дүнг оруулна уу';
  static const allAssigned = 'Бүгд хуваарилагдсан';
  static String leftToAssign(String amount) => '$amount үлдсэн';
  static String tooMuch(String amount) => '$amount илүү байна';
  static const splitEvenly = 'Тэнцүү хуваах';
  static const percentAssigned = '100% хуваарилагдсан';
  static const whatWasItFor = 'Юунд зарцуулсан бэ?';
  static const pickSomeone = 'Дор хаяж нэг хүн сонгоно уу';
  static String checkAmountFor(String name) => '$name: дүнг шалгана уу';
  static String checkPercentFor(String name) => '$name: хувийг шалгана уу';
  static const enterOneShare = 'Дор хаяж нэг хүний хувийг оруулна уу';
  static String sharesMustAddUpTo(String amount) => 'Хуваалтын нийлбэр $amount байх ёстой';
  static const percentMustBe100 = 'Хувийн нийлбэр 100% байх ёстой';
  static const saveOffline = 'Холболт тасарлаа. "$save" товчийг дахин дарна уу. Зардал давхар бүртгэгдэхгүй.';
  static const reenterPercents = 'Хуучин хувийг хадгалдаггүй тул хувиа дахин оруулна уу.';
  static String exactShareFor(String name) => '$name: дүн';
  static String percentShareFor(String name) => '$name: хувь';

  // ---------------------------------------------------------------- expense
  static const expense = 'Зардал';
  static const expenseNotFound = 'Зардал олдсонгүй.';
  static String expenseMeta(String payer, String date, String splitLabel) =>
      '$payer төлсөн · $date · $splitLabel хуваалт';
  static const receipt = 'Баримт';
  static const camera = 'Камер';
  static const photos = 'Зургийн сан';
  static const uploading = 'Байршуулж байна…';
  static const noReceiptYet = 'Баримт хавсаргаагүй байна';
  static const couldNotLoadReceipt = 'Ачаалж чадсангүй. Дахин оролдох';
  static const editExpense = 'Зардал засах';
  static const deleteExpense = 'Зардал устгах';
  static const deleteExpenseQuestion = 'Энэ зардлыг устгах уу? Хүн бүрийн тооцоо шинэчлэгдэнэ.';
  static const expenseDeleted = 'Зардал устлаа';
  static const expenseSaved = 'Зардал хадгалагдлаа';
  static const expenseChangedTitle = 'Зардал өөрчлөгдсөн байна';
  static const expenseChanged =
      'Таныг засаж байх хооронд өөр хүн энэ зардлыг өөрчилсөн байна. Шинэ мэдээллийг ачааллаа, шалгаад дахин засна уу.';
  static String editedBy(String name, String date) => 'Зассан: $name · $date';

  // ---------------------------------------------------------------- settle up
  static const everyoneSettled = 'Бүх хүний тооцоо тэнцүү байна.';
  static const settleUpHint =
      'Хүн бүрийн тооцоог тэглэх хамгийн цөөн төлбөрүүд. Мөнгө бодитоор шилжсэний дараа төлбөрөө бүртгээрэй.';
  static String transfer(String from, String to) => '$from → $to';
  static const record = 'Бүртгэх';
  static const recordedPayments = 'Бүртгэсэн төлбөрүүд';
  static const partialPaymentHelper = 'Хэсэгчлэн төлсөн бол дүнг өөрчилнө үү.';
  static const recordPayment = 'Төлбөр бүртгэх';
  static const notRecorded = 'Бүртгэгдсэнгүй';
  static const paymentRecorded = 'Төлбөр бүртгэгдлээ';
  static String paymentFrom(String name, String amount) => '$name: $amount';
  static const recordOffline = 'Холболт тасарлаа. Дахин оролдоно уу. Төлбөр давхар бүртгэгдэхгүй.';
  static const deletePayment = 'Төлбөр устгах';
  static const deletePaymentQuestion = 'Энэ бүртгэсэн төлбөрийг устгах уу? Хүн бүрийн тооцоо шинэчлэгдэнэ.';
  static const paymentDeleted = 'Төлбөр устлаа';

  // ---------------------------------------------------------------- home tabs
  static const tabGroups = 'Бүлгүүд';
  static const tabBills = 'Тооцоо';

  // ---------------------------------------------------------------- bills (QR bill splitting)
  static const billsTitle = 'Тооцоо хуваах';
  static const newBill = 'Шинэ тооцоо';
  static const editBill = 'Тооцоо засах';
  static const noBillsYet = 'Одоогоор тооцоо алга';
  static const noBillsHint =
      'Ресторан, үдэшлэгийн тооцоогоо оруулаад QR кодоо найзууддаа уншуулаарай. '
      'Тэд бүртгүүлэхгүйгээр идсэн зүйлээ сонгож, танд шилжүүлнэ.';
  static const billTitle = 'Гарчиг';
  static const billTitleHint = 'Оройн хоол, төрсөн өдөр…';
  static const items = 'Зүйлс';
  static const itemName = 'Нэр';
  static const itemNameHint = 'Хуушуур';
  static const price = 'Үнэ';
  static const addItem = 'Мөр нэмэх';
  static const remove = 'Устгах';
  static String itemsTotal(String amount) => 'Нийт: $amount';
  static const whereToPay = 'Хаана шилжүүлэх вэ?';
  static const whereToPayHint = 'Зочид энэ мэдээллийг харж, танд шилжүүлнэ. Дараагийн тооцоонд автоматаар бөглөгдөнө.';
  static const bank = 'Банк';
  static const accountNumber = 'Дансны дугаар';
  static const accountName = 'Данс эзэмшигчийн нэр';
  static const payQr = 'Банкны QR зураг';
  static const payQrHint = 'Банкны аппынхаа "QR-ээр хүлээн авах" дэлгэцийн зургийг оруулбал зочид уншуулж төлнө.';
  static const uploadQr = 'QR зураг оруулах';
  static const replaceQr = 'Солих';
  static const billTitleRequired = 'Гарчгаа оруулна уу';
  static const needOneItem = 'Дор хаяж нэг зүйл оруулна уу';
  static String itemRowIncomplete(int row) => '$row-р мөр: нэр болон үнээ зөв оруулна уу';
  static const paymentIncomplete = 'Банк, дансны дугаар, эзэмшигчийн нэрээ бүгдийг нь оруулна уу';
  static const createBillAndQr = 'Үүсгээд QR гаргах';
  static const banks = [
    'Хаан банк',
    'Голомт банк',
    'Худалдаа хөгжлийн банк',
    'Хас банк',
    'Төрийн банк',
    'Капитрон банк',
    'Богд банк',
    'Ариг банк',
    'Транс банк',
    'М банк',
    'Чингис хаан банк',
    'Үндэсний хөрөнгө оруулалтын банк',
  ];

  // Bill detail
  static const scanToJoin = 'Найзууд тань энэ QR кодыг утасныхаа камераар уншуулна. Апп суулгах шаардлагагүй.';
  static const shareLink = 'Илгээх';
  static const copyLink = 'Хуулах';
  static const linkCopied = 'Холбоос хуулагдлаа';
  static String shareText(String title, String url) => '$title: идсэн зүйлээ сонгоод төлөх дүнгээ хараарай $url';
  static const total = 'Нийт';
  static const unclaimed = 'Хэн ч сонгоогүй';
  static const collected = 'Цугларсан';
  static String collectedOf(String paid, String owed) => '$paid / $owed';
  static const myItems = 'Миний идсэн';
  static const myItemsHint = 'Өөрийн идсэн зүйлсээ сонгоно уу. Хамт идсэн зүйл таны болон зочдын дунд хуваагдана.';
  static const guests = 'Зочид';
  static const noGuestsYet = 'Одоогоор хэн ч нэгдээгүй байна.';
  static const paidBadge = 'Төлсөн';
  static const markPaid = 'Төлсөн гэж тэмдэглэх';
  static const markUnpaid = 'Төлөөгүй болгох';
  static String removeGuestQuestion(String name) => 'Энэ зочныг хасах уу? ($name)';
  static const nobodyClaimed = 'Хэн ч сонгоогүй';
  static const billOpen = 'Нээлттэй';
  static const billClosed = 'Хаагдсан';
  static const closeBill = 'Тооцоог хаах';
  static const reopenBill = 'Дахин нээх';
  static const closedBanner = 'Тооцоо хаагдсан. Зочид сонголтоо өөрчлөх боломжгүй, гэхдээ төлбөрөө тэмдэглэж болно.';
  static String paidOf(int paid, int count) => '$paid/$count төлсөн';
  static String transferNote(String code) => 'Гүйлгээний утга: $code + нэр';
  static String paidShort(String amount) => 'Төлсөн: $amount';
  static String stillOwes(String amount) => 'Дутуу: $amount';
  static String paidTooMuch(String amount) => 'Илүү төлсөн: $amount';
  static const deleteBill = 'Тооцоо устгах';
  static const deleteBillQuestion = 'Энэ тооцоог устгах уу? QR холбоос ажиллахаа болино. Буцаах боломжгүй.';
  static const billDeleted = 'Тооцоо устлаа';
  static const newLink = 'Шинэ холбоос';
  static const newLinkQuestion = 'Шинэ холбоос үүсгэх үү?';
  static const newLinkWarning =
      'Хуучин QR код болон холбоос ажиллахаа болино. Шинэ QR кодоо зочиддоо дахин уншуулах эсвэл илгээх хэрэгтэй.';
  static const newLinkCreated = 'Шинэ холбоос үүслээ';
  static const reopenToEdit = 'Тооцоо хаагдсан байна. Засварыг хадгалахын тулд эхлээд "$reopenBill" дарна уу.';

  // ---------------------------------------------------------------- account
  static const accountTitle = 'Миний бүртгэл';
  static const deleteAccount = 'Бүртгэл устгах';
  static const deleteAccountQuestion = 'Бүртгэлээ устгах уу?';
  static const deleteAccountWarning =
      'Таныг бүх бүлгээс гаргаж, таны үүсгэсэн тооцоонууд болон бүртгэлийг бүрмөсөн устгана. Буцаах боломжгүй.';
  static String deleteAccountBlocked(List<String> groups) =>
      'Дараах бүлгүүдэд таны тооцоо тэглэгдээгүй байна: ${groups.join(', ')}. Эхлээд тооцоогоо хаана уу.';
  static const accountDeleted = 'Бүртгэл устлаа';
  static const emailNotVerified = 'И-мэйл хаяг тань баталгаажаагүй тул бүлгийн урилга танд ирэхгүй.';

  // ---------------------------------------------------------------- dates
  /// "11-р сарын 5"
  static String date(DateTime d) {
    final local = d.toLocal();
    return '${local.month}-р сарын ${local.day}';
  }

  /// "11-р сар", for the small calendar chip on expense rows.
  static String month(DateTime d) => '${d.toLocal().month}-р сар';

  // ---------------------------------------------------------------- server errors
  /// The server's error codes (backend/src) in Mongolian. Unknown codes get a generic message.
  static String apiError(String code) => switch (code) {
    'NETWORK' => noConnection,
    'UNAUTHORIZED' => sessionExpired,
    'GROUP_NOT_FOUND' => 'Бүлэг олдсонгүй.',
    'EXPENSE_NOT_FOUND' => expenseNotFound,
    'RECEIPT_NOT_FOUND' => 'Баримт олдсонгүй.',
    'PAYER_NOT_MEMBER' => 'Төлсөн хүн энэ бүлгийн гишүүн биш байна.',
    'SPLIT_USER_NOT_MEMBER' => 'Хуваалтад бүлгийн гишүүн биш хүн орсон байна.',
    'SETTLEMENT_USER_NOT_MEMBER' => 'Төлбөрийн оролцогч бүлгийн гишүүн биш байна.',
    'NOT_A_PARTY' => 'Та зөвхөн өөрийн оролцсон төлбөрийг бүртгэх, устгах боломжтой.',
    'EXPENSE_CHANGED' => expenseChanged,
    'SETTLEMENT_NOT_FOUND' => 'Төлбөр олдсонгүй. Өөр хүн устгасан байж магадгүй.',
    'BALANCE_NOT_ZERO' => 'Тооцоо тэглэгдээгүй байна. Эхлээд тооцоогоо хаана уу.',
    'BALANCES_NOT_ZERO' => 'Тэглэгдээгүй тооцоо байна. Эхлээд бүх тооцоогоо хаана уу.',
    'INVITE_NOT_FOUND' => 'Урилга олдсонгүй. Цуцлагдсан эсвэл аль хэдийн ашиглагдсан байж магадгүй.',
    'ALREADY_MEMBER' => 'Энэ и-мэйлтэй хүн аль хэдийн бүлгийн гишүүн байна.',
    'GROUP_FULL' => 'Нэг бүлэгт гишүүд болон урилга нийлээд 50-аас хэтрэх боломжгүй.',
    'CANNOT_REMOVE_SELF' => 'Өөрийгөө хасах боломжгүй. "$leaveGroup" товчийг ашиглана уу.',
    'MEMBER_NOT_FOUND' => 'Гишүүн олдсонгүй. Аль хэдийн хасагдсан байж магадгүй.',
    'INVALID_UPLOAD_KEY' || 'UPLOAD_NOT_FOUND' => 'Зураг бүрэн байршсангүй. Дахин оролдоно уу.',
    'FILE_TOO_LARGE' => fileTooLarge,
    'UPLOAD_FAILED' => uploadFailed,
    'IDEMPOTENCY_KEY_REUSED' => 'Энэ хүсэлт өөр мэдээлэлтэйгээр аль хэдийн илгээгдсэн байна. Дахин оролдоно уу.',
    'VALIDATION_ERROR' => 'Оруулсан мэдээллээ шалгана уу.',
    'INVALID_AMOUNT' => 'Дүн буруу байна.',
    'SPLIT_EMPTY' => 'Дор хаяж нэг хүнийг хуваалтад оруулна уу.',
    'SPLIT_DUPLICATE_USER' => 'Нэг хүн хуваалтад давхар орсон байна.',
    'INVALID_WEIGHT' || 'INVALID_PERCENT' => 'Хувь буруу байна.',
    'SPLIT_PERCENT_MISMATCH' => percentMustBe100,
    'SPLIT_SUM_MISMATCH' => 'Хуваалтын нийлбэр нийт дүнтэй тэнцүү байх ёстой.',
    'BILL_NOT_FOUND' => 'Тооцоо олдсонгүй.',
    'BILL_CLOSED' => reopenToEdit,
    'BILL_FULL' => 'Нэг тооцоонд 50-аас олон хүн нэгдэх боломжгүй.',
    'GUEST_NOT_FOUND' => 'Зочин олдсонгүй.',
    'CANNOT_REMOVE_HOST' => 'Тооцоог төлсөн хүнийг хасах боломжгүй.',
    _ => somethingWentWrong,
  };

  /// Server validation errors, by field path. The server's own wording is English, so it isn't shown.
  static String fieldError(String path) => switch (path) {
    'email' => enterValidEmail,
    'name' => 'Нэрээ шалгана уу',
    'description' => 'Тайлбараа шалгана уу',
    'amountCents' => amountHint,
    'currency' => 'Валютаа шалгана уу',
    'title' => billTitleRequired,
    _ => 'Утга буруу байна',
  };
}
