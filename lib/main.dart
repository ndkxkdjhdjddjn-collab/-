package com.example

import android.app.AppOpsManager
import android.app.Application
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.room.*
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.random.Random

// ==========================================
// 1. DATA LAYER (ROOM DATABASE)
// ==========================================

@Entity(tableName = "study_sessions")
data class StudySession(
  @PrimaryKey(autoGenerate = true) val id: Long = 0,
  val startTime: Long,
  val endTime: Long,
  val durationSeconds: Int,
  val subject: String,
  val mode: String,
  val completed: Boolean,
  val interruptionsBlocked: Int = 0,
  val date: String
)

@Dao
interface StudySessionDao {
  @Insert(onConflict = OnConflictStrategy.REPLACE)
  suspend fun insertSession(session: StudySession): Long

  @Delete
  suspend fun deleteSession(session: StudySession)

  @Query("SELECT * FROM study_sessions ORDER BY startTime DESC")
  fun getAllSessions(): Flow<List<StudySession>>
}

@Database(entities = [StudySession::class], version = 1, exportSchema = false)
abstract class AppDatabase : RoomDatabase() {
  abstract fun studySessionDao(): StudySessionDao

  companion object {
    @Volatile private var INSTANCE: AppDatabase? = null
    fun getDatabase(context: Context): AppDatabase {
      return INSTANCE ?: synchronized(this) {
        Room.databaseBuilder(context.applicationContext, AppDatabase::class.java, "focus_flip_db")
          .fallbackToDestructiveMigration().build().also { INSTANCE = it }
      }
    }
  }
}

// ==========================================
// 2. APP BLOCKER & USAGE STATS MANAGER
// ==========================================

data class BlockedAppInfo(
  val packageName: String,
  val appName: String,
  val isBlocked: Boolean = false,
  val category: String = "Other",
  val icon: Drawable? = null
)

object AppBlockerManager {
  fun hasUsageStatsPermission(context: Context): Boolean {
    val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager ?: return false
    val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
    } else {
      @Suppress("DEPRECATION")
      appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
    }
    return mode == AppOpsManager.MODE_ALLOWED
  }

  fun openUsageAccessSettings(context: Context) {
    try {
      context.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK })
    } catch (_: Exception) {
      context.startActivity(Intent(Settings.ACTION_SETTINGS).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK })
    }
  }

  fun getInstalledApps(context: Context): List<BlockedAppInfo> {
    val pm = context.packageManager
    val mainIntent = Intent(Intent.ACTION_MAIN, null).apply { addCategory(Intent.CATEGORY_LAUNCHER) }
    val resolveInfos = pm.queryIntentActivities(mainIntent, 0)
    val appList = mutableListOf<BlockedAppInfo>()
    val seenPackages = mutableSetOf<String>()

    for (resolveInfo in resolveInfos) {
      val pkg = resolveInfo.activityInfo.packageName
      if (pkg == context.packageName || seenPackages.contains(pkg)) continue
      seenPackages.add(pkg)

      val appName = resolveInfo.loadLabel(pm).toString()
      val icon = try { resolveInfo.loadIcon(pm) } catch (_: Exception) { null }
      val category = when {
        pkg.contains("insta") || pkg.contains("tiktok") || pkg.contains("twitter") ||
        pkg.contains("facebook") || pkg.contains("snapchat") || pkg.contains("reddit") -> "Social Media"
        pkg.contains("youtube") || pkg.contains("netflix") || pkg.contains("music") -> "Entertainment"
        pkg.contains("game") || pkg.contains("play") -> "Games"
        else -> "Productivity / Utilities"
      }
      appList.add(BlockedAppInfo(pkg, appName, false, category, icon))
    }
    return appList.sortedWith(compareBy({ it.category }, { it.appName.lowercase() }))
  }

  fun getTopForegroundPackage(context: Context): String? {
    val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager ?: return null
    val endTime = System.currentTimeMillis()
    val events = usageStatsManager.queryEvents(endTime - 10_000, endTime)
    val event = UsageEvents.Event()
    var lastForeground: String? = null

    while (events.hasNextEvent()) {
      events.getNextEvent(event)
      if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED) {
        lastForeground = event.packageName
      }
    }
    return lastForeground
  }
}

// ==========================================
// 3. VIEWMODEL & STATE MANAGEMENT
// ==========================================

enum class ClockDisplayMode { LIVE_CLOCK, POMODORO, STOPWATCH }
enum class TimerStatus { IDLE, RUNNING, PAUSED, FINISHED }
enum class StrictLockType { NONE, LONG_PRESS, MATH_CHALLENGE }

data class FocusUiState(
  val clockMode: ClockDisplayMode = ClockDisplayMode.POMODORO,
  val timerStatus: TimerStatus = TimerStatus.IDLE,
  val currentPhase: String = "FOCUS",
  val subject: String = "General Study",
  val presetMinutes: Int = 25,
  val totalDurationSeconds: Int = 25 * 60,
  val remainingSeconds: Int = 25 * 60,
  val elapsedSeconds: Int = 0,
  val interruptionsBlocked: Int = 0,
  val liveHours: String = "12",
  val liveMinutes: String = "00",
  val liveSeconds: String = "00",
  val liveAmPm: String? = null,
  val is24Hour: Boolean = true,
  val showSeconds: Boolean = true,
  val keepScreenAwake: Boolean = true,
  val oledTrueBlack: Boolean = true,
  val strictLockType: StrictLockType = StrictLockType.MATH_CHALLENGE,
  val isZenFullscreen: Boolean = false,
  val isBlockerActive: Boolean = true,
  val installedApps: List<BlockedAppInfo> = emptyList(),
  val blockedPackages: Set<String> = emptySet(),
  val hasUsagePermission: Boolean = false,
  val blockedAppTriggered: String? = null
)

class FocusViewModel(
  application: Application,
  private val dao: StudySessionDao
) : AndroidViewModel(application) {

  private val _uiState = MutableStateFlow(FocusUiState())
  val uiState: StateFlow<FocusUiState> = _uiState.asStateFlow()

  val allSessions: StateFlow<List<StudySession>> = dao.getAllSessions()
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

  private var timerJob: Job? = null
  private var liveClockJob: Job? = null
  private var blockerWatcherJob: Job? = null
  private var sessionStartTimeMs: Long = 0L

  init {
    startLiveClock()
    refreshPermissions()
    loadApps()
  }

  fun refreshPermissions() {
    val context = getApplication<Application>()
    val hasUsage = AppBlockerManager.hasUsageStatsPermission(context)
    _uiState.update { it.copy(hasUsagePermission = hasUsage) }
  }

  fun loadApps() {
    viewModelScope.launch {
      val context = getApplication<Application>()
      val apps = AppBlockerManager.getInstalledApps(context)
      val defaultBlocked = apps.filter { it.category == "Social Media" }.map { it.packageName }.toSet()
      _uiState.update {
        it.copy(
          installedApps = apps.map { app -> app.copy(isBlocked = defaultBlocked.contains(app.packageName)) },
          blockedPackages = defaultBlocked
        )
      }
    }
  }

  fun toggleAppBlocked(packageName: String) {
    _uiState.update { state ->
      val newBlocked = state.blockedPackages.toMutableSet()
      if (newBlocked.contains(packageName)) newBlocked.remove(packageName) else newBlocked.add(packageName)
      state.copy(
        blockedPackages = newBlocked,
        installedApps = state.installedApps.map { if (it.packageName == packageName) it.copy(isBlocked = newBlocked.contains(packageName)) else it }
      )
    }
  }

  fun blockCategory(category: String, block: Boolean) {
    _uiState.update { state ->
      val newBlocked = state.blockedPackages.toMutableSet()
      state.installedApps.filter { it.category == category }.forEach { app ->
        if (block) newBlocked.add(app.packageName) else newBlocked.remove(app.packageName)
      }
      state.copy(
        blockedPackages = newBlocked,
        installedApps = state.installedApps.map { it.copy(isBlocked = newBlocked.contains(it.packageName)) }
      )
    }
  }

  fun setClockMode(mode: ClockDisplayMode) { _uiState.update { it.copy(clockMode = mode) } }
  fun setSubject(subject: String) { _uiState.update { it.copy(subject = subject) } }

  fun selectPreset(minutes: Int, phase: String = "FOCUS") {
    if (_uiState.value.timerStatus == TimerStatus.RUNNING) return
    val sec = minutes * 60
    _uiState.update {
      it.copy(presetMinutes = minutes, currentPhase = phase, totalDurationSeconds = sec, remainingSeconds = sec, elapsedSeconds = 0, timerStatus = TimerStatus.IDLE)
    }
  }

  fun toggle24Hour(is24: Boolean) { _uiState.update { it.copy(is24Hour = is24) }; updateLiveClock() }
  fun toggleKeepScreenAwake(keep: Boolean) { _uiState.update { it.copy(keepScreenAwake = keep) } }
  fun toggleOledTrueBlack(black: Boolean) { _uiState.update { it.copy(oledTrueBlack = black) } }
  fun setStrictLockType(type: StrictLockType) { _uiState.update { it.copy(strictLockType = type) } }
  fun setMasterBlockerActive(active: Boolean) { _uiState.update { it.copy(isBlockerActive = active) } }
  fun toggleZenFullscreen() { _uiState.update { it.copy(isZenFullscreen = !it.isZenFullscreen) } }
  fun setZenFullscreen(fullscreen: Boolean) { _uiState.update { it.copy(isZenFullscreen = fullscreen) } }
  fun dismissBlockedOverlay() { _uiState.update { it.copy(blockedAppTriggered = null) } }

  fun startTimer() {
    if (_uiState.value.timerStatus == TimerStatus.RUNNING) return
    sessionStartTimeMs = System.currentTimeMillis()
    _uiState.update { it.copy(timerStatus = TimerStatus.RUNNING) }
    startBlockerWatcher()

    timerJob?.cancel()
    timerJob = viewModelScope.launch {
      while (isActive && _uiState.value.timerStatus == TimerStatus.RUNNING) {
        delay(1000L)
        if (_uiState.value.clockMode == ClockDisplayMode.STOPWATCH) {
          _uiState.update { it.copy(elapsedSeconds = it.elapsedSeconds + 1) }
        } else {
          val remaining = _uiState.value.remainingSeconds - 1
          val elapsed = _uiState.value.elapsedSeconds + 1
          if (remaining <= 0) {
            _uiState.update { it.copy(remainingSeconds = 0, elapsedSeconds = elapsed, timerStatus = TimerStatus.FINISHED) }
            saveSession(completed = true)
            break
          } else {
            _uiState.update { it.copy(remainingSeconds = remaining, elapsedSeconds = elapsed) }
          }
        }
      }
    }
  }

  fun pauseTimer() {
    _uiState.update { it.copy(timerStatus = TimerStatus.PAUSED) }
    timerJob?.cancel()
    blockerWatcherJob?.cancel()
  }

  fun resetTimer() {
    timerJob?.cancel()
    blockerWatcherJob?.cancel()
    val sec = _uiState.value.presetMinutes * 60
    _uiState.update { it.copy(timerStatus = TimerStatus.IDLE, remainingSeconds = sec, elapsedSeconds = 0, interruptionsBlocked = 0) }
  }

  fun finishSessionEarly() {
    if (_uiState.value.elapsedSeconds >= 60) saveSession(completed = false)
    resetTimer()
  }

  private fun saveSession(completed: Boolean) {
    viewModelScope.launch {
      val state = _uiState.value
      val durationSec = if (state.clockMode == ClockDisplayMode.STOPWATCH) state.elapsedSeconds else state.totalDurationSeconds - state.remainingSeconds
      val dateStr = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Date())
      dao.insertSession(
        StudySession(
          startTime = sessionStartTimeMs, endTime = System.currentTimeMillis(),
          durationSeconds = durationSec, subject = state.subject, mode = state.clockMode.name,
          completed = completed, interruptionsBlocked = state.interruptionsBlocked, date = dateStr
        )
      )
    }
  }

  fun deleteSession(session: StudySession) {
    viewModelScope.launch { dao.deleteSession(session) }
  }

  private fun startBlockerWatcher() {
    if (!_uiState.value.isBlockerActive) return
    blockerWatcherJob?.cancel()
    blockerWatcherJob = viewModelScope.launch {
      val context = getApplication<Application>()
      while (isActive && _uiState.value.timerStatus == TimerStatus.RUNNING) {
        delay(1200L)
        if (AppBlockerManager.hasUsageStatsPermission(context)) {
          val topPkg = AppBlockerManager.getTopForegroundPackage(context)
          if (topPkg != null && topPkg != context.packageName && _uiState.value.blockedPackages.contains(topPkg)) {
            val appInfo = _uiState.value.installedApps.find { it.packageName == topPkg }
            _uiState.update {
              it.copy(interruptionsBlocked = it.interruptionsBlocked + 1, blockedAppTriggered = appInfo?.appName ?: topPkg)
            }
            try {
              context.startActivity(Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
              })
            } catch (_: Exception) {}
          }
        }
      }
    }
  }

  private fun startLiveClock() {
    liveClockJob = viewModelScope.launch {
      while (isActive) {
        updateLiveClock()
        delay(500L)
      }
    }
  }

  private fun updateLiveClock() {
    val cal = Calendar.getInstance()
    val is24 = _uiState.value.is24Hour
    val hoursVal = if (is24) cal.get(Calendar.HOUR_OF_DAY) else {
      val h = cal.get(Calendar.HOUR); if (h == 0) 12 else h
    }
    _uiState.update {
      it.copy(
        liveHours = String.format(Locale.US, "%02d", hoursVal),
        liveMinutes = String.format(Locale.US, "%02d", cal.get(Calendar.MINUTE)),
        liveSeconds = String.format(Locale.US, "%02d", cal.get(Calendar.SECOND)),
        liveAmPm = if (!is24) if (cal.get(Calendar.AM_PM) == Calendar.AM) "AM" else "PM" else null
      )
    }
  }
}

class FocusViewModelFactory(private val app: Application, private val dao: StudySessionDao) : ViewModelProvider.Factory {
  @Suppress("UNCHECKED_CAST")
  override fun <T : ViewModel> create(modelClass: Class<T>): T = FocusViewModel(app, dao) as T
}

// ==========================================
// 4. UI COMPONENTS (FLIP CLOCK & DIALOGS)
// ==========================================

@Composable
fun MechanicalFlipCard(
  digit: String,
  cardWidth: Dp = 60.dp,
  cardHeight: Dp = 90.dp,
  textColor: Color = Color(0xFFF8FAFC),
  cardBgColor: Color = Color(0xFF1E222E)
) {
  var currentDigit by remember { mutableStateOf(digit) }
  var oldDigit by remember { mutableStateOf(digit) }
  val anim = remember { Animatable(1f) }

  LaunchedEffect(digit) {
    if (digit != currentDigit) {
      oldDigit = currentDigit
      currentDigit = digit
      anim.snapTo(0f)
      anim.animateTo(1f, tween(320, easing = FastOutSlowInEasing))
    }
  }

  val progress = anim.value
  val halfH = cardHeight / 2
  val corner = 8.dp

  Box(modifier = Modifier.size(cardWidth, cardHeight).shadow(8.dp, RoundedCornerShape(corner))) {
    Column(modifier = Modifier.fillMaxSize()) {
      CardHalfView(currentDigit, isTop = true, cardWidth, halfH, corner, cardBgColor, textColor)
      Spacer(modifier = Modifier.height(1.dp).background(Color(0xFF0F1117)))
      CardHalfView(oldDigit, isTop = false, cardWidth, halfH, corner, cardBgColor, textColor)
    }

    if (progress < 0.5f) {
      val rot = progress * 2f * 90f
      Box(modifier = Modifier.size(cardWidth, halfH).align(Alignment.TopCenter).graphicsLayer {
        rotationX = -rot; cameraDistance = 16f * density; transformOrigin = TransformOrigin(0.5f, 1f)
      }) {
        CardHalfView(oldDigit, isTop = true, cardWidth, halfH, corner, cardBgColor, textColor)
      }
    } else {
      val sub = (progress - 0.5f) * 2f
      Box(modifier = Modifier.size(cardWidth, halfH).align(Alignment.BottomCenter).graphicsLayer {
        rotationX = 90f - (sub * 90f); cameraDistance = 16f * density; transformOrigin = TransformOrigin(0.5f, 0f)
      }) {
        CardHalfView(currentDigit, isTop = false, cardWidth, halfH, corner, cardBgColor, textColor)
      }
    }

    Box(modifier = Modifier.fillMaxWidth().height(2.dp).align(Alignment.Center).background(Color(0xFF0F1117)))
  }
}

@Composable
fun CardHalfView(text: String, isTop: Boolean, w: Dp, h: Dp, corner: Dp, bg: Color, tc: Color) {
  val shape = if (isTop) RoundedCornerShape(topStart = corner, topEnd = corner) else RoundedCornerShape(bottomStart = corner, bottomEnd = corner)
  Box(
    modifier = Modifier.size(w, h).clip(shape).background(bg).border(0.5.dp, Color(0xFF2C3242), shape),
    contentAlignment = if (isTop) Alignment.BottomCenter else Alignment.TopCenter
  ) {
    Text(
      text = text, color = tc, fontSize = (h.value * 1.35f).sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace,
      modifier = Modifier.graphicsLayer { translationY = if (isTop) (h.value * 0.45f) * 2.75f else -((h.value * 0.45f) * 2.75f) }
    )
  }
}

@Composable
fun FlipClockDisplay(
  hours: String? = null, minutes: String, seconds: String, amPm: String? = null,
  accentColor: Color = Color(0xFFF59E0B)
) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
    if (hours != null) {
      Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        MechanicalFlipCard(hours.take(1))
        MechanicalFlipCard(hours.drop(1))
      }
      Text(" : ", color = accentColor, fontSize = 28.sp, fontWeight = FontWeight.Bold)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
      MechanicalFlipCard(minutes.take(1))
      MechanicalFlipCard(minutes.drop(1))
    }
    Text(" : ", color = accentColor, fontSize = 28.sp, fontWeight = FontWeight.Bold)
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
      MechanicalFlipCard(seconds.take(1), 46.dp, 70.dp, accentColor)
      MechanicalFlipCard(seconds.drop(1), 46.dp, 70.dp, accentColor)
    }
    if (amPm != null) {
      Spacer(modifier = Modifier.width(8.dp))
      Text(amPm, color = accentColor, fontWeight = FontWeight.Bold, fontSize = 12.sp)
    }
  }
}

@Composable
fun MathChallengeDialog(onDismiss: () -> Unit, onSolved: () -> Unit) {
  val n1 = remember { Random.nextInt(15, 60) }
  val n2 = remember { Random.nextInt(10, 40) }
  val expected = n1 + n2
  var ans by remember { mutableStateOf("") }
  var err by remember { mutableStateOf(false) }

  Dialog(onDismissRequest = onDismiss) {
    Box(modifier = Modifier.fillMaxWidth().background(Color(0xFF141822), RoundedCornerShape(16.dp)).padding(20.dp)) {
      Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Default.Warning, null, tint = Color(0xFFEF4444))
        Spacer(modifier = Modifier.height(8.dp))
        Text("Strict Focus Lock", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text("Solve this to exit session:", color = Color(0xFF94A3B8), fontSize = 13.sp)
        Spacer(modifier = Modifier.height(14.dp))
        Text("$n1 + $n2 = ?", color = Color(0xFFF59E0B), fontSize = 24.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
        Spacer(modifier = Modifier.height(14.dp))
        OutlinedTextField(
          value = ans, onValueChange = { ans = it; err = false },
          singleLine = true, isError = err, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
          label = { Text("Answer") }, modifier = Modifier.fillMaxWidth()
        )
        Spacer(modifier = Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
          OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text("Keep Studying") }
          Button(
            onClick = { if (ans.trim().toIntOrNull() == expected) onSolved() else err = true },
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626)), modifier = Modifier.weight(1f)
          ) { Text("Exit") }
        }
      }
    }
  }
}

@Composable
fun LongPressExitDialog(onDismiss: () -> Unit, onExit: () -> Unit) {
  var isHold by remember { mutableStateOf(false) }
  var prog by remember { mutableFloatStateOf(0f) }

  LaunchedEffect(isHold) {
    if (isHold) {
      var s = 0
      while (isHold && s < 60) { delay(100L); s++; prog = s / 60f }
      if (isHold && prog >= 1f) onExit()
    } else prog = 0f
  }

  Dialog(onDismissRequest = onDismiss) {
    Box(modifier = Modifier.fillMaxWidth().background(Color(0xFF141822), RoundedCornerShape(16.dp)).padding(20.dp)) {
      Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Strict Hold Lock", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text("Hold button for 6 seconds to quit:", color = Color(0xFF94A3B8), fontSize = 13.sp)
        Spacer(modifier = Modifier.height(20.dp))
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(110.dp)) {
          CircularProgressIndicator(progress = { prog }, modifier = Modifier.size(106.dp), color = Color(0xFFEF4444), strokeWidth = 6.dp)
          Box(
            modifier = Modifier.size(86.dp).background(if (isHold) Color(0xFF7F1D1D) else Color(0xFF1F2937), CircleShape)
              .pointerInput(Unit) { detectTapGestures(onPress = { isHold = true; tryAwaitRelease(); isHold = false }) },
            contentAlignment = Alignment.Center
          ) {
            Text(if (isHold) "${((1f - prog) * 6).toInt() + 1}s" else "HOLD", color = Color.White, fontWeight = FontWeight.Bold)
          }
        }
        Spacer(modifier = Modifier.height(20.dp))
        OutlinedButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
      }
    }
  }
}

@Composable
fun BlockedAppOverlay(name: String, onDismiss: () -> Unit) {
  Box(modifier = Modifier.fillMaxSize().background(Color(0xFF1A0505)).padding(24.dp), contentAlignment = Alignment.Center) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
      Icon(Icons.Default.Block, null, tint = Color(0xFFEF4444), modifier = Modifier.size(64.dp))
      Spacer(modifier = Modifier.height(14.dp))
      Text("ACCESS RESTRICTED", color = Color(0xFFEF4444), fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
      Text("$name is Blocked", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
      Spacer(modifier = Modifier.height(10.dp))
      Text("You are currently in a focus session. Stay disciplined!", color = Color(0xFF94A3B8), textAlign = TextAlign.Center)
      Spacer(modifier = Modifier.height(28.dp))
      Button(onClick = onDismiss, colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626))) {
        Text("Return to FocusFlip")
      }
    }
  }
}

// ==========================================
// 5. SCREENS
// ==========================================

@Composable
fun FocusClockScreen(viewModel: FocusViewModel, uiState: FocusUiState) {
  var showMath by remember { mutableStateOf(false) }
  var showHold by remember { mutableStateOf(false) }
  val accentColor = if (uiState.currentPhase == "FOCUS") Color(0xFFF59E0B) else Color(0xFF10B981)

  Box(modifier = Modifier.fillMaxSize().background(if (uiState.oledTrueBlack) Color.Black else Color(0xFF090D14))) {
    Column(
      modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
      horizontalAlignment = Alignment.CenterHorizontally
    ) {
      Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(uiState.subject, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
        IconButton(onClick = { viewModel.toggleZenFullscreen() }) {
          Icon(Icons.Default.Fullscreen, null, tint = Color(0xFF94A3B8))
        }
      }

      Spacer(modifier = Modifier.height(12.dp))

      Row(modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Color(0xFF131722)).padding(4.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
        ClockModeTabItem("Pomodoro", uiState.clockMode == ClockDisplayMode.POMODORO) { viewModel.setClockMode(ClockDisplayMode.POMODORO) }
        ClockModeTabItem("Wall Clock", uiState.clockMode == ClockDisplayMode.LIVE_CLOCK) { viewModel.setClockMode(ClockDisplayMode.LIVE_CLOCK) }
        ClockModeTabItem("Stopwatch", uiState.clockMode == ClockDisplayMode.STOPWATCH) { viewModel.setClockMode(ClockDisplayMode.STOPWATCH) }
      }

      Spacer(modifier = Modifier.height(30.dp))

      when (uiState.clockMode) {
        ClockDisplayMode.LIVE_CLOCK -> FlipClockDisplay(uiState.liveHours, uiState.liveMinutes, uiState.liveSeconds, uiState.liveAmPm, accentColor)
        ClockDisplayMode.STOPWATCH -> {
          val m = String.format(Locale.US, "%02d", uiState.elapsedSeconds / 60)
          val s = String.format(Locale.US, "%02d", uiState.elapsedSeconds % 60)
          FlipClockDisplay(null, m, s, null, accentColor)
        }
        ClockDisplayMode.POMODORO -> {
          val rem = uiState.remainingSeconds
          val m = String.format(Locale.US, "%02d", rem / 60)
          val s = String.format(Locale.US, "%02d", rem % 60)
          FlipClockDisplay(null, m, s, null, accentColor)
        }
      }

      Spacer(modifier = Modifier.height(28.dp))

      if (uiState.clockMode == ClockDisplayMode.POMODORO && uiState.timerStatus != TimerStatus.RUNNING) {
        Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
          Button(onClick = { viewModel.selectPreset(25, "FOCUS") }) { Text("25m Study") }
          Button(onClick = { viewModel.selectPreset(50, "FOCUS") }) { Text("50m Deep") }
          Button(onClick = { viewModel.selectPreset(5, "SHORT_BREAK") }) { Text("5m Break") }
          Button(onClick = { viewModel.selectPreset(15, "LONG_BREAK") }) { Text("15m Rest") }
        }
        Spacer(modifier = Modifier.height(20.dp))
      }

      if (uiState.clockMode != ClockDisplayMode.LIVE_CLOCK) {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
          if (uiState.timerStatus == TimerStatus.RUNNING || uiState.timerStatus == TimerStatus.PAUSED) {
            OutlinedButton(onClick = {
              when (uiState.strictLockType) {
                StrictLockType.MATH_CHALLENGE -> showMath = true
                StrictLockType.LONG_PRESS -> showHold = true
                StrictLockType.NONE -> viewModel.finishSessionEarly()
              }
            }) { Text("Stop", color = Color(0xFFEF4444)) }
          }

          val running = uiState.timerStatus == TimerStatus.RUNNING
          Button(
            onClick = { if (running) viewModel.pauseTimer() else viewModel.startTimer() },
            colors = ButtonDefaults.buttonColors(containerColor = accentColor)
          ) {
            Text(if (running) "Pause" else "Start Focus", color = Color.Black, fontWeight = FontWeight.Bold)
          }
        }
      }
    }

    if (uiState.blockedAppTriggered != null) {
      BlockedAppOverlay(uiState.blockedAppTriggered) { viewModel.dismissBlockedOverlay() }
    }
    if (showMath) MathChallengeDialog(onDismiss = { showMath = false }) { showMath = false; viewModel.finishSessionEarly() }
    if (showHold) LongPressExitDialog(onDismiss = { showHold = false }) { showHold = false; viewModel.finishSessionEarly() }
  }
}

@Composable
fun ClockModeTabItem(title: String, sel: Boolean, onClick: () -> Unit) {
  Box(
    modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(if (sel) Color(0xFF232A3B) else Color.Transparent)
      .clickable { onClick() }.padding(horizontal = 14.dp, vertical = 6.dp)
  ) {
    Text(title, color = if (sel) Color(0xFFF59E0B) else Color(0xFF64748B), fontWeight = FontWeight.Bold)
  }
}

@Composable
fun AppBlockerScreen(viewModel: FocusViewModel, uiState: FocusUiState) {
  val context = LocalContext.current
  LazyColumn(
    modifier = Modifier.fillMaxSize().background(Color.Black).padding(16.dp),
    verticalArrangement = Arrangement.spacedBy(12.dp)
  ) {
    item {
      Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text("App Blocker Shield", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Switch(checked = uiState.isBlockerActive, onCheckedChange = { viewModel.setMasterBlockerActive(it) })
      }
      Text("${uiState.blockedPackages.size} apps blocked during sessions", color = Color(0xFF94A3B8), fontSize = 13.sp)
    }

    if (!uiState.hasUsagePermission) {
      item {
        Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF2D1618)), modifier = Modifier.fillMaxWidth()) {
          Column(modifier = Modifier.padding(14.dp)) {
            Text("Usage Access Permission Required", color = Color(0xFFF87171), fontWeight = FontWeight.Bold)
            Text("Required by Android to detect background apps during study sessions.", color = Color(0xFFE2E8F0), fontSize = 12.sp)
            Spacer(modifier = Modifier.height(8.dp))
            Button(onClick = { AppBlockerManager.openUsageAccessSettings(context) }, colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626))) {
              Text("Grant Usage Access")
            }
          }
        }
      }
    }

    item {
      Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(onClick = { viewModel.blockCategory("Social Media", true) }) { Text("Block Social") }
        Button(onClick = { viewModel.blockCategory("Entertainment", true) }) { Text("Block Media") }
      }
    }

    items(uiState.installedApps, key = { it.packageName }) { app ->
      val blocked = uiState.blockedPackages.contains(app.packageName)
      Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Color(0xFF131722))
          .padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically
      ) {
        Column(modifier = Modifier.weight(1f)) {
          Text(app.appName, color = Color.White, fontWeight = FontWeight.SemiBold)
          Text(app.category, color = Color(0xFF64748B), fontSize = 11.sp)
        }
        Switch(checked = blocked, onCheckedChange = { viewModel.toggleAppBlocked(app.packageName) })
      }
    }
  }
}

@Composable
fun StatisticsScreen(viewModel: FocusViewModel, uiState: FocusUiState) {
  val sessions by viewModel.allSessions.collectAsState()
  val totalSec = remember(sessions) { sessions.sumOf { it.durationSeconds } }
  val totalHours = totalSec / 3600
  val totalMins = (totalSec % 3600) / 60

  LazyColumn(modifier = Modifier.fillMaxSize().background(Color.Black).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
    item {
      Text("Study Statistics", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
      Text("Total Focus: ${totalHours}h ${totalMins}m across ${sessions.size} sessions", color = Color(0xFF94A3B8), fontSize = 13.sp)
    }

    items(sessions) { s ->
      Card(colors = CardDefaults.cardColors(containerColor = Color(0xFF131722)), modifier = Modifier.fillMaxWidth()) {
        Row(modifier = Modifier.padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
          Column {
            Text(s.subject, color = Color.White, fontWeight = FontWeight.Bold)
            Text("${s.date} • ${s.durationSeconds / 60} minutes", color = Color(0xFF64748B), fontSize = 12.sp)
          }
          IconButton(onClick = { viewModel.deleteSession(s) }) {
            Icon(Icons.Default.Delete, null, tint = Color(0xFF64748B))
          }
        }
      }
    }
  }
}

@Composable
fun SettingsScreen(viewModel: FocusViewModel, uiState: FocusUiState) {
  Column(modifier = Modifier.fillMaxSize().background(Color.Black).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
    Text("Settings", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)

    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("24-Hour Format", color = Color.White)
      Switch(checked = uiState.is24Hour, onCheckedChange = { viewModel.toggle24Hour(it) })
    }

    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("Keep Screen Awake (Wakelock)", color = Color.White)
      Switch(checked = uiState.keepScreenAwake, onCheckedChange = { viewModel.toggleKeepScreenAwake(it) })
    }

    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
      Text("OLED True Black", color = Color.White)
      Switch(checked = uiState.oledTrueBlack, onCheckedChange = { viewModel.toggleOledTrueBlack(it) })
    }

    Text("Strict Exit Hurdle:", color = Color.White, fontWeight = FontWeight.Bold)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
      Button(onClick = { viewModel.setStrictLockType(StrictLockType.MATH_CHALLENGE) }) { Text("Math") }
      Button(onClick = { viewModel.setStrictLockType(StrictLockType.LONG_PRESS) }) { Text("Hold") }
      Button(onClick = { viewModel.setStrictLockType(StrictLockType.NONE) }) { Text("None") }
    }
  }
}

// ==========================================
// 6. MAIN ACTIVITY ENTRY POINT
// ==========================================

enum class AppTab { FOCUS, BLOCKER, STATS, SETTINGS }

class MainActivity : ComponentActivity() {
  private lateinit var viewModel: FocusViewModel

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    enableEdgeToEdge()

    val db = AppDatabase.getDatabase(applicationContext)
    val factory = FocusViewModelFactory(application, db.studySessionDao())
    viewModel = ViewModelProvider(this, factory)[FocusViewModel::class.java]

    setContent {
      val uiState by viewModel.uiState.collectAsState()
      var currentTab by remember { mutableStateOf(AppTab.FOCUS) }

      DisposableEffect(uiState.keepScreenAwake, uiState.timerStatus) {
        val awake = uiState.keepScreenAwake && (uiState.timerStatus == TimerStatus.RUNNING || uiState.isZenFullscreen)
        if (awake) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
      }

      BackHandler(enabled = currentTab != AppTab.FOCUS || uiState.isZenFullscreen) {
        if (uiState.isZenFullscreen) viewModel.setZenFullscreen(false) else currentTab = AppTab.FOCUS
      }

      Scaffold(
        containerColor = Color.Black,
        bottomBar = {
          if (!uiState.isZenFullscreen) {
            NavigationBar(containerColor = Color(0xFF0E121B)) {
              NavigationBarItem(
                selected = currentTab == AppTab.FOCUS, onClick = { currentTab = AppTab.FOCUS },
                icon = { Icon(Icons.Default.HourglassTop, null) }, label = { Text("Focus") }
              )
              NavigationBarItem(
                selected = currentTab == AppTab.BLOCKER, onClick = { currentTab = AppTab.BLOCKER },
                icon = { Icon(Icons.Default.Shield, null) }, label = { Text("Blocker") }
              )
              NavigationBarItem(
                selected = currentTab == AppTab.STATS, onClick = { currentTab = AppTab.STATS },
                icon = { Icon(Icons.Default.BarChart, null) }, label = { Text("Stats") }
              )
              NavigationBarItem(
                selected = currentTab == AppTab.SETTINGS, onClick = { currentTab = AppTab.SETTINGS },
                icon = { Icon(Icons.Default.Settings, null) }, label = { Text("Settings") }
              )
            }
          }
        }
      ) { pad ->
        Box(modifier = Modifier.fillMaxSize().padding(pad)) {
          when (currentTab) {
            AppTab.FOCUS -> FocusClockScreen(viewModel, uiState)
            AppTab.BLOCKER -> AppBlockerScreen(viewModel, uiState)
            AppTab.STATS -> StatisticsScreen(viewModel, uiState)
            AppTab.SETTINGS -> SettingsScreen(viewModel, uiState)
          }
        }
      }
    }
  }

  override fun onResume() {
    super.onResume()
    viewModel.refreshPermissions()
  }
